//
//  CardFileSystem.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  The ONLY code in the app that creates, overwrites, moves or deletes
//  files on the card. Every method asks `PathGuard` first.
//
//  HOW IT FITS
//      SyncExecutor ──▶ CardFileSystem ──check──▶ PathGuard
//                              │
//                              └──▶ FileManager / POSIX calls
//
//  COPYING, STEP BY STEP (`copyFromMac`)
//  1. Open the Mac file READ-ONLY (`FileHandle(forReadingFrom:)`).
//  2. Write into a temp file in `.q2sync/tmp/` on the card, in 1 MB chunks,
//     checking for Cancel between chunks.
//  3. Flush it to the card (`synchronize`), so the data is really there.
//  4. Check the temp file's size equals the Mac file's size.
//  5. Copy the Mac file's creation/modification dates (Q2 Pod sorts
//     "Recently Added" by creation date).
//  6. Remove extended attributes macOS attached to the new file, then
//     rename the temp file into place. A rename is all-or-nothing, so the
//     card never holds a half-written song under its real name.
//  7. Delete any leftover `._` companion file (see "AppleDouble" below).
//
//  APPLEDOUBLE ("._") FILES
//  FAT and exFAT can't store macOS extended attributes, so macOS keeps them
//  in a hidden companion file, e.g. `._01 Hello.m4a`. macOS adds such an
//  attribute to every file a sandboxed app creates, and some players list
//  these companions as broken songs. So after each copy or move we strip
//  the attributes and remove the companion of OUR file only, via the
//  guard's narrow `checkAppleDoubleCompanion` exception.
//

import Foundation

/// Problems copying files, beyond guard refusals.
enum CardFileError: LocalizedError, Equatable {
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case sourceUnreadable(String)
    case notEmptyFolder(String)

    var errorDescription: String? {
        switch self {
        case .sizeMismatch(let expected, let actual):
            return "The copy on the card has the wrong size (\(actual) bytes, expected \(expected))."
        case .sourceUnreadable(let reason):
            return "The song file on your Mac couldn't be read: \(reason)"
        case .notEmptyFolder(let path):
            return "The folder isn't empty: \(path)"
        }
    }
}

/// Guarded file operations on the card.
struct CardFileSystem: Sendable {

    /// The gatekeeper consulted before every change.
    let pathGuard: PathGuard

    /// Size of each read/write chunk when copying.
    static let chunkSize = 1 << 20 // 1 MB

    /// Card folder for temp files (inside the app's own hidden folder).
    var tempFolder: CardPath { "\(pathGuard.profile.appStateFolderName)/tmp" }

    // MARK: - Reading (no guard needed: reading changes nothing)

    /// The absolute URL for a card path, WITHOUT approval. Only for reading.
    func urlForReading(_ path: CardPath) -> URL {
        pathGuard.cardRoot.appending(path: path)
    }

    /// The size of a card file, or `nil` if it doesn't exist.
    func fileSize(at path: CardPath) -> UInt64? {
        let values = try? urlForReading(path).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else { return nil }
        return UInt64(size)
    }

    // MARK: - Folders

    /// Creates a folder and any missing parents, each one approved.
    ///
    /// - Parameter path: e.g. `"Music/Adele/25"`.
    /// - Throws: `PathGuard.Violation` or file-system errors.
    func createDirectory(_ path: CardPath) throws {
        var built: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            built.append(component)
            let partial = built.joined(separator: "/")
            let url = try pathGuard.check(partial, for: .createDirectory)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue { throw CocoaError(.fileWriteFileExists) }
                continue
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    // MARK: - Copying

    /// Copies a song from the Mac to the card safely (see file header).
    ///
    /// - Parameters:
    ///   - source: The Mac file. Opened read-only; never modified.
    ///   - destination: Card path to create or replace.
    ///   - onProgress: Called with the bytes written by each chunk.
    /// - Returns: The number of bytes copied.
    /// - Throws: Guard violations, `CardFileError`, `CancellationError`,
    ///   or file-system errors. The temp file is removed on any failure.
    @discardableResult
    func copyFromMac(source: URL, to destination: CardPath,
                     onProgress: (Int) -> Void = { _ in }) throws -> UInt64 {
        // Approve both the temp file and the final destination up front.
        try createDirectory(tempFolder)
        let tempPath = "\(tempFolder)/\(UUID().uuidString).part"
        let tempURL = try pathGuard.check(tempPath, for: .write)
        let destinationURL = try pathGuard.check(destination, for: .write)
        let parent = (destination as NSString).deletingLastPathComponent
        if !parent.isEmpty { try createDirectory(parent) }

        do {
            let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let sourceSize = (sourceAttributes[.size] as? NSNumber)?.uint64Value ?? 0

            // Step 1: read-only source handle.
            let input: FileHandle
            do { input = try FileHandle(forReadingFrom: source) }
            catch { throw CardFileError.sourceUnreadable(error.localizedDescription) }
            defer { try? input.close() }

            // Step 2: write the temp file chunk by chunk.
            guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: tempURL)
            var written: UInt64 = 0
            do {
                while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: chunk)
                    written += UInt64(chunk.count)
                    onProgress(chunk.count)
                }
                // Step 3: make sure the bytes are on the card.
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }

            // Step 4: verify the size on the card.
            let tempSize = (try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?
                .uint64Value ?? 0
            guard tempSize == sourceSize, written == sourceSize else {
                throw CardFileError.sizeMismatch(expected: sourceSize, actual: tempSize)
            }

            // Step 5: keep the original dates.
            var dates: [FileAttributeKey: Any] = [:]
            if let created = sourceAttributes[.creationDate] { dates[.creationDate] = created }
            if let modified = sourceAttributes[.modificationDate] { dates[.modificationDate] = modified }
            if !dates.isEmpty { try? FileManager.default.setAttributes(dates, ofItemAtPath: tempURL.path) }

            // Step 6: drop extended attributes, then atomic rename into place
            // (replaces an older copy).
            Self.removeExtendedAttributes(at: tempURL)
            try Self.rename(tempURL, to: destinationURL)

            // Step 7: remove a `._` companion if macOS made one anyway.
            removeAppleDoubleCompanion(of: destination)
            return tempSize
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - Moving and deleting

    /// Renames a card file from one approved path to another.
    ///
    /// - Throws: Guard violations or file-system errors. Refuses to
    ///   overwrite an existing file at the destination.
    func move(_ source: CardPath, to destination: CardPath) throws {
        let sourceURL = try pathGuard.check(source, for: .delete)
        let destinationURL = try pathGuard.check(destination, for: .write)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        let parent = (destination as NSString).deletingLastPathComponent
        if !parent.isEmpty { try createDirectory(parent) }
        try Self.rename(sourceURL, to: destinationURL)
        removeAppleDoubleCompanion(of: destination)
    }

    /// Deletes one card file.
    ///
    /// - Parameters:
    ///   - path: The file to delete.
    ///   - confirmedByUser: `true` only for card-only files the user chose
    ///     to delete in the confirmation dialog (allows paths outside the
    ///     app's folders, but never reserved items).
    func removeFile(_ path: CardPath, confirmedByUser: Bool = false) throws {
        let url = try pathGuard.check(path, for: confirmedByUser ? .deleteConfirmedByUser : .delete)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        guard !isDirectory.boolValue else { throw CardFileError.notEmptyFolder(path) }
        try FileManager.default.removeItem(at: url)
    }

    /// Moves a card file into the card's trash folder instead of deleting it:
    /// `.q2sync/Trash/<batch>/<original path>`.
    ///
    /// - Parameters:
    ///   - path: The file to move.
    ///   - batch: Folder name for this sync, e.g. "2026-11-15 at 15.30.00".
    ///   - confirmedByUser: As for `removeFile`.
    func moveToTrash(_ path: CardPath, batch: String, confirmedByUser: Bool = false) throws {
        let sourceURL = try pathGuard.check(path, for: confirmedByUser ? .deleteConfirmedByUser : .delete)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        let trashRoot = "\(pathGuard.profile.appStateFolderName)/Trash"
        try ensureTrashIsHiddenFromLibrary(trashRoot)
        var destination = "\(trashRoot)/\(batch)/\(path)"
        var number = 2
        while fileSize(at: destination) != nil {
            destination = CardLayout.variant(of: "\(trashRoot)/\(batch)/\(path)", number: number)
            number += 1
        }
        let destinationURL = try pathGuard.check(destination, for: .write)
        try createDirectory((destination as NSString).deletingLastPathComponent)
        try Self.rename(sourceURL, to: destinationURL)
    }

    /// Puts an empty `database.ignore` file in the trash folder so Q2 Pod's
    /// library scan doesn't list trashed songs. (Stock firmware may ignore
    /// this marker; trashed songs are inside a hidden folder either way.)
    private func ensureTrashIsHiddenFromLibrary(_ trashRoot: CardPath) throws {
        try createDirectory(trashRoot)
        let marker = "\(trashRoot)/database.ignore"
        if fileSize(at: marker) == nil {
            try writeAtomically(Data(), to: marker)
        }
    }

    /// Removes empty folders left behind by moves/deletes, walking up from
    /// `path`'s folder but never removing the top-level managed folder.
    ///
    /// Only truly empty folders go (`rmdir` refuses non-empty ones), so a
    /// folder holding anything at all, even a `.DS_Store`, stays.
    func removeEmptyFolders(above path: CardPath) {
        var folder = (path as NSString).deletingLastPathComponent
        while folder.contains("/") {
            guard let url = try? pathGuard.check(folder, for: .delete),
                  Darwin.rmdir(url.path) == 0 else { return }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    // MARK: - Small files (manifest, markers)

    /// Writes data to a card file via a temp file and rename.
    func writeAtomically(_ data: Data, to path: CardPath) throws {
        try createDirectory(tempFolder)
        let tempURL = try pathGuard.check("\(tempFolder)/\(UUID().uuidString).part", for: .write)
        let destinationURL = try pathGuard.check(path, for: .write)
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty { try createDirectory(parent) }
        do {
            try data.write(to: tempURL)
            try Self.rename(tempURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - AppleDouble companions

    /// What happened when tidying a `._` companion.
    enum CompanionRemoval: Equatable {
        /// There was no companion file.
        case none
        /// The companion was deleted.
        case removed
        /// It couldn't be deleted; the reason goes in the sync log.
        case failed(String)
    }

    /// Deletes the `._` companion of a managed file, if there is one.
    ///
    /// - Parameter path: The main file, e.g. `"Music/A/B/01 X.m4a"`.
    /// - Returns: What happened, so the sync log can explain failures.
    @discardableResult
    func removeAppleDoubleCompanion(of path: CardPath) -> CompanionRemoval {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let companionPath = urlForReading(folder.isEmpty ? "._\(name)" : "\(folder)/._\(name)").path
        // `lstat` returns -1 when there's nothing there: the normal case.
        var info = stat()
        guard lstat(companionPath, &info) == 0 else { return .none }
        do {
            let companion = try pathGuard.checkAppleDoubleCompanion(of: path)
            guard Darwin.unlink(companion.path) == 0 else {
                return .failed("\(path): \(String(cString: strerror(errno)))")
            }
            return .removed
        } catch {
            return .failed("\(path): \(error.localizedDescription)")
        }
    }

    /// Removes every extended attribute from a file we just created on the
    /// card (so macOS has nothing to put in a `._` companion).
    /// Attributes macOS won't let us remove are simply left; step 7 then
    /// cleans up the companion file instead.
    ///
    /// - Parameter url: An approved card file.
    static func removeExtendedAttributes(at url: URL) {
        // First ask for the size of the name list, then fetch it. Names are
        // C strings separated by NUL bytes.
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &buffer, size, XATTR_NOFOLLOW) == size else { return }
        let names = buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        for name in names {
            _ = removexattr(url.path, name, XATTR_NOFOLLOW)
        }
    }

    /// Deletes leftover temp files from an interrupted sync.
    func cleanTempFolder() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: urlForReading(tempFolder).path) else { return }
        for name in names where name.hasSuffix(".part") {
            if let url = try? pathGuard.check("\(tempFolder)/\(name)", for: .delete) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// POSIX `rename`, which replaces the destination in one step. Both URLs
    /// must already be approved by the guard.
    private static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
