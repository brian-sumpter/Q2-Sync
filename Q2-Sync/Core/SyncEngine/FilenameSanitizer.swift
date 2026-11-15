//
//  FilenameSanitizer.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Turns tag text ("AC/DC", "What's Up?", "Live: 1999…") into file and
//  folder names that are safe on FAT32 and exFAT cards AND on the Q2's
//  Linux system, which reads the card.
//
//  RULES (each one prevents a real problem)
//  1. Unicode is normalised to NFC ("é" as one character, not "e" + accent),
//     so the bytes we write match the bytes we later put in playlists.
//  2. Characters FAT/exFAT forbid — \ / : * ? " < > | — and control
//     characters become "_".
//  3. Leading/trailing spaces are trimmed; trailing dots are removed
//     (Windows and FAT drivers drop them, which would break paths).
//  4. A leading "." becomes "_", otherwise the item would be hidden on the
//     Q2 and treated as a reserved item by the app.
//  5. DOS device names (CON, PRN, AUX, NUL, COM1–9, LPT1–9) get a "_"
//     appended; some FAT drivers refuse them.
//  6. Each name is limited to `maximumComponentBytes` UTF-8 bytes, cut at a
//     whole character. Linux limits names to 255 bytes; we stay well below
//     so whole paths stay short too. File extensions are always kept.
//  7. An empty result becomes a fallback like "Unknown Artist".
//

import Foundation

/// Makes strings safe to use as card file and folder names.
enum FilenameSanitizer {

    /// Longest allowed file or folder name, in UTF-8 bytes.
    static let maximumComponentBytes = 100

    /// Characters FAT32 and exFAT do not allow in names.
    private static let forbiddenCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")

    /// Reserved DOS device names (compared case-insensitively, before any dot).
    private static let reservedDeviceNames: Set<String> = {
        var names: Set<String> = ["con", "prn", "aux", "nul"]
        for number in 1...9 {
            names.insert("com\(number)")
            names.insert("lpt\(number)")
        }
        return names
    }()

    /// Sanitises a folder name or a file name without extension.
    ///
    /// - Parameters:
    ///   - raw: The text to clean, e.g. an artist name.
    ///   - fallback: Used if nothing is left after cleaning.
    ///   - maximumBytes: Byte limit for the result.
    /// - Returns: A safe name, never empty.
    static func sanitizeComponent(_ raw: String, fallback: String,
                                  maximumBytes: Int = maximumComponentBytes) -> String {
        // Rule 1: NFC normalisation.
        var name = raw.precomposedStringWithCanonicalMapping

        // Rule 2: replace forbidden and control characters, one at a time.
        name = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F
                || CharacterSet.controlCharacters.contains(scalar)
            return (isControl || forbiddenCharacters.contains(scalar)) ? "_" : scalar
        }))

        // Rules 3 and 4.
        name = trimEnds(name)
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }

        // Rule 5.
        let beforeDot = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        if reservedDeviceNames.contains(beforeDot.lowercased()) { name += "_" }

        // Rule 6, then tidy the ends again (cutting may leave a space or dot).
        name = trimEnds(truncate(name, maximumBytes: maximumBytes))

        // Rule 7.
        return name.isEmpty ? fallback : name
    }

    /// Sanitises a file name, keeping its extension intact.
    ///
    /// - Parameters:
    ///   - base: The name without extension, e.g. "01 Hello".
    ///   - fileExtension: e.g. "m4a" (no dot). Lowercased in the result.
    ///   - fallback: Used for an empty base.
    /// - Returns: e.g. `"01 Hello.m4a"`, within the byte limit.
    static func sanitizeFileName(base: String, fileExtension: String, fallback: String = "Track") -> String {
        let ext = sanitizeComponent(fileExtension, fallback: "", maximumBytes: 10)
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let baseLimit = maximumComponentBytes - suffix.utf8.count
        let cleanBase = sanitizeComponent(base, fallback: fallback, maximumBytes: baseLimit)
        return cleanBase + suffix
    }

    /// Cuts a string to at most `maximumBytes` UTF-8 bytes without splitting
    /// a character (so an emoji or accented letter is never cut in half).
    ///
    /// - Returns: The longest whole-character prefix that fits.
    static func truncate(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maximumBytes { break }
            result.append(character)
            used += size
        }
        return result
    }

    /// Removes leading/trailing whitespace and trailing dots, repeatedly,
    /// so "Album. ." becomes "Album".
    private static func trimEnds(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") || result.hasSuffix(" ") {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
