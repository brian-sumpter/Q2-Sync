//
//  CardScanner.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Lists the files currently on the card (read-only), so the planner can
//  compare reality with the manifest: is each managed song really there
//  and the right size? Is there an unmanaged file in the way?
//
//  HOW IT FITS
//  Called by the sync coordinator before planning. The card-only finder
//  also uses it to find "card-only" music anywhere on the card.
//
//  Reserved items (hidden folders, firmware files…) are skipped entirely.
//

import Foundation

/// One file found on the card.
struct CardFile: Sendable, Hashable {
    /// Path relative to the card root (NFC-normalised).
    let path: CardPath
    /// Size in bytes.
    let size: UInt64
}

/// Read-only listing of card files.
enum CardScanner {

    /// File extensions treated as music when looking for card-only files.
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "alac", "wav", "aif", "aiff", "ogg", "oga", "opus",
        "wma", "ape", "dsf", "dff", "m4b",
    ]

    /// Lists every non-reserved file under a card folder.
    ///
    /// - Parameters:
    ///   - folder: Card path to scan, e.g. `"Music"`; `""` scans the whole card.
    ///   - fileSystem: The card.
    /// - Returns: Files keyed by `CardLayout.caseKey` of their path.
    /// - Side effects: None (reads directory listings and sizes only).
    static func scan(folder: CardPath, on fileSystem: CardFileSystem) -> [String: CardFile] {
        let root = fileSystem.pathGuard.cardRoot
        let start = folder.isEmpty ? root : root.appending(path: folder)
        let rules = fileSystem.pathGuard.profile.reservedItems
        var result: [String: CardFile] = [:]

        guard let enumerator = FileManager.default.enumerator(
            at: start,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [] // Hidden items are checked by the reserved rules below.
        ) else { return result }

        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"

        // `for case let x as T in` loops over items, keeping only those of type T.
        for case let url as URL in enumerator {
            let fullPath = url.path
            guard fullPath.hasPrefix(rootPrefix) else { continue }
            let relative = String(fullPath.dropFirst(rootPrefix.count)).precomposedStringWithCanonicalMapping
            let components = relative.split(separator: "/").map(String.init)

            // Don't descend into reserved folders at all.
            if rules.isReserved(components: components) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            // Symlinks are never followed or counted (a FAT card shouldn't have
            // any; if one appears, we leave it completely alone).
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values?.isRegularFile == true else { continue }
            result[CardLayout.caseKey(relative)] = CardFile(path: relative, size: UInt64(values?.fileSize ?? 0))
        }
        return result
    }
}
