//
//  CardLayout.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Decides where each song goes on the card:
//
//      Music/<Album Artist>/<Album>/<disc-track> <Title>.<ext>
//      e.g.  Music/Adele/25/01 Hello.m4a
//            Music/Pink Floyd/The Wall/2-03 Hey You.mp3   (multi-disc)
//
//  HOW IT FITS
//  The sync planner asks `CardLayout` for each track's preferred path and
//  uses its helpers to handle two songs that would get the same name.
//
//  CONVENTIONS
//  "Relative paths" in this app are relative to the card root, use "/" as
//  the separator, and are NFC-normalised (see FilenameSanitizer).
//  FAT and exFAT ignore case, so two paths that differ only in case are the
//  same file: compare paths with `caseKey(_:)`.
//

import Foundation

/// A path relative to the card root, e.g. `"Music/Adele/25/01 Hello.m4a"`.
typealias CardPath = String

/// Card folder layout for one device profile.
struct CardLayout: Sendable {

    /// The device profile (folder names, mount point).
    let profile: DeviceProfile

    /// The preferred card path for a track.
    ///
    /// - Parameter track: The library track.
    /// - Returns: e.g. `"Music/Adele/25/01 Hello.m4a"`.
    func preferredPath(for track: Track) -> CardPath {
        let artistFolder = FilenameSanitizer.sanitizeComponent(track.effectiveAlbumArtist, fallback: "Unknown Artist")
        let albumFolder = FilenameSanitizer.sanitizeComponent(track.displayAlbum, fallback: "Unknown Album")
        let ext = track.fileURL?.pathExtension ?? ""
        let fileName = FilenameSanitizer.sanitizeFileName(base: numberPrefix(for: track) + track.title,
                                                          fileExtension: ext)
        return [profile.musicFolderName, artistFolder, albumFolder, fileName].joined(separator: "/")
    }

    /// "01 ", "2-03 ", or "" when the track number is unknown.
    ///
    /// The disc number is only added for multi-disc albums, so single-disc
    /// albums get the familiar "01 Title" names.
    private func numberPrefix(for track: Track) -> String {
        guard track.trackNumber > 0 else { return "" }
        let number = String(format: "%02d", track.trackNumber)
        let isMultiDisc = track.discCount > 1 || track.discNumber > 1
        return isMultiDisc ? "\(max(track.discNumber, 1))-\(number) " : "\(number) "
    }

    /// The Nth alternative name for a path, used when two different songs
    /// would otherwise share a name: `"01 Intro.mp3"` → `"01 Intro (2).mp3"`.
    ///
    /// - Parameters:
    ///   - path: The preferred path.
    ///   - number: 2, 3, 4…
    /// - Returns: The numbered variant.
    static func variant(of path: CardPath, number: Int) -> CardPath {
        let (folder, base, ext) = split(path)
        let suffix = " (\(number))"
        let limitedBase = FilenameSanitizer.truncate(
            base, maximumBytes: FilenameSanitizer.maximumComponentBytes - suffix.utf8.count - ext.utf8.count - 1)
        let name = limitedBase + suffix + (ext.isEmpty ? "" : ".\(ext)")
        return folder.isEmpty ? name : "\(folder)/\(name)"
    }

    /// `true` if `path` is `preferred` or one of its numbered variants,
    /// ignoring case. Used to keep an existing file's " (2)" name stable.
    static func isSameOrVariant(_ path: CardPath, of preferred: CardPath) -> Bool {
        if caseKey(path) == caseKey(preferred) { return true }
        // Read the number from a trailing " (n)", rebuild that variant of
        // the preferred path, and compare. Exact, so no false matches.
        let (_, base, _) = split(path)
        guard let range = base.range(of: #" \((\d+)\)$"#, options: .regularExpression) else { return false }
        let digits = base[range].filter(\.isNumber)
        guard let number = Int(digits), number >= 2 else { return false }
        return caseKey(variant(of: preferred, number: number)) == caseKey(path)
    }

    /// A comparison key that treats paths the way FAT/exFAT do:
    /// case-insensitive, Unicode-normalised.
    static func caseKey(_ path: CardPath) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The path as the Q2 sees it, e.g. `/mnt/mmc/Music/Adele/25/01 Hello.m4a`.
    func devicePath(for path: CardPath) -> String {
        "\(profile.deviceMountPoint)/\(path)"
    }

    /// Splits `"Music/A/B/01 X.mp3"` into `("Music/A/B", "01 X", "mp3")`.
    private static func split(_ path: CardPath) -> (folder: String, base: String, ext: String) {
        let slash = path.lastIndex(of: "/")
        let folder = slash.map { String(path[..<$0]) } ?? ""
        let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (folder, name, "") }
        return (folder, String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
