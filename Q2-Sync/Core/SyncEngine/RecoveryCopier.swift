//
//  RecoveryCopier.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  "Copy to Mac" for card-only music: copies a file FROM the card into a
//  staging folder on the Mac, ~/Downloads/Q2 Recovered, so you can add it
//  to Music yourself (File › Import). It never writes into your Music
//  library or its media folder.
//
//  HOW IT FITS
//  The executor calls `copyBack` for items set to "Copy to Mac", before
//  any deletions. It's the only code that writes to the Mac outside the
//  app's own container, and it has its own guard (`checkDestination`).
//
//  RULES
//  • Destinations must resolve strictly inside the staging folder.
//  • Never inside ~/Music or the Apple Music media folder (checked even
//    though the staging folder is in Downloads).
//  • Never overwrite: an identical file already there (same size and
//    SHA-256) is skipped as a duplicate; a different one gets " (2)".
//  • The card file is opened read-only and left on the card.
//  • Each copy is written to a temp name, checked, then renamed.
//  • Every copy is listed in RECOVERED.txt in the staging folder.
//

import CryptoKit
import Foundation

/// What happened to one copy-back.
enum RecoveryResult: Sendable, Equatable {
    /// Copied to this Mac file.
    case copied(URL)
    /// An identical file was already in the staging folder.
    case duplicate(URL)
}

/// Problems copying back.
enum RecoveryError: LocalizedError, Equatable {
    case destinationRefused(String)
    case sizeMismatch

    var errorDescription: String? {
        switch self {
        case .destinationRefused(let path): return "Refused to copy to \(path): it's outside the Q2 Recovered folder or inside your Music folder."
        case .sizeMismatch: return "The copy on your Mac has the wrong size."
        }
    }
}

/// Copies card-only music to the Mac's staging folder.
struct RecoveryCopier: Sendable {

    /// The staging folder, e.g. ~/Downloads/Q2 Recovered.
    let stagingFolder: URL

    /// Folders that must never be written: ~/Music and the media folder.
    let protectedFolders: [URL]

    /// The default staging folder in the REAL Downloads folder (not the
    /// sandbox container's).
    static var defaultStagingFolder: URL {
        PathGuard.realHomeDirectory.appending(path: "Downloads/Q2 Recovered", directoryHint: .isDirectory)
    }

    /// Copies one card file to the staging folder.
    ///
    /// - Parameters:
    ///   - source: The card file (read only).
    ///   - cardPath: Its card path; the copy keeps this layout, minus a
    ///     leading "Music/" (e.g. "Music/Adele/25/x.m4a" → "Adele/25/x.m4a").
    /// - Returns: Where it went, or that it was a duplicate.
    /// - Throws: `RecoveryError` or file errors.
    func copyBack(source: URL, cardPath: CardPath) throws -> RecoveryResult {
        var relative = cardPath
        if relative.lowercased().hasPrefix("music/") { relative = String(relative.dropFirst("music/".count)) }

        var destination = try checkDestination(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // Duplicate check / never overwrite.
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            if try Self.sameContents(source, destination) { return .duplicate(destination) }
            destination = try checkDestination(CardLayout.variant(of: relative, number: number))
            number += 1
        }

        // Copy to a temp name, verify, rename.
        let temp = destination.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).q2recovering")
        do {
            let input = try FileHandle(forReadingFrom: source) // read-only
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: temp)
            while let chunk = try input.read(upToCount: CardFileSystem.chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            try output.close()

            let sourceSize = try Self.size(of: source)
            guard try Self.size(of: temp) == sourceSize else { throw RecoveryError.sizeMismatch }
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        appendToList("\(cardPath)  →  \(destination.path)")
        return .copied(destination)
    }

    /// Checks a destination path inside the staging folder.
    ///
    /// - Parameter relative: Path relative to the staging folder.
    /// - Returns: The approved absolute URL.
    /// - Throws: `RecoveryError.destinationRefused`.
    func checkDestination(_ relative: String) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw RecoveryError.destinationRefused(relative)
        }
        try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        guard let root = PathGuard.realPath(stagingFolder.path),
              let resolved = PathGuard.resolve(stagingFolder.appending(path: relative).path),
              PathGuard.isInside(resolved, folder: root) else {
            throw RecoveryError.destinationRefused(relative)
        }
        for folder in protectedFolders {
            let protected = PathGuard.realPath(folder.path) ?? folder.standardizedFileURL.path
            if resolved == protected || PathGuard.isInside(resolved, folder: protected)
                || root == protected || PathGuard.isInside(root, folder: protected) {
                throw RecoveryError.destinationRefused(resolved)
            }
        }
        return URL(filePath: resolved)
    }

    /// Appends a line to RECOVERED.txt in the staging folder.
    private func appendToList(_ line: String) {
        let list = stagingFolder.appending(path: "RECOVERED.txt")
        if !FileManager.default.fileExists(atPath: list.path) {
            let header = "Songs copied from your Q2 by Q2 Sync. Add them to Music with File › Import.\n\n"
            FileManager.default.createFile(atPath: list.path, contents: Data(header.utf8))
        }
        guard let handle = try? FileHandle(forWritingTo: list) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        try? handle.write(contentsOf: Data("\(stamp)  \(line)\n".utf8))
    }

    /// File size in bytes.
    private static func size(of url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// `true` if two files have the same size and SHA-256 hash.
    static func sameContents(_ a: URL, _ b: URL) throws -> Bool {
        guard try size(of: a) == size(of: b) else { return false }
        return try sha256(a) == sha256(b)
    }

    /// SHA-256 of a file, read in chunks.
    private static func sha256(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: CardFileSystem.chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}
