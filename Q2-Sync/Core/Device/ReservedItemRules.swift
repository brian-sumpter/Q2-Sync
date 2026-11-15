//
//  ReservedItemRules.swift
//  Q2-Sync › Core › Device
//
//  PURPOSE
//  Decides whether a path on the card belongs to the firmware (or another
//  app) and must therefore never be modified, deleted, or reported as
//  "card-only music".
//
//  HOW IT FITS
//  Each `DeviceProfile` carries one `ReservedItemRules`. Two places use it:
//    • `PathGuard` refuses any write/delete of a reserved path.
//    • The card scanner skips reserved items when looking for
//      music that isn't on the Mac.
//
//  THE RULES, in order
//  A path (relative to the card root) is reserved if ANY component:
//    1. starts with "." (hidden), unless it's the app's own state folder.
//       This one rule covers macOS metadata (._*, .DS_Store, .Spotlight-V100,
//       .fseventsd, .Trashes) and every hidden firmware folder (.rockbox,
//       .sldp, .coverflow, .q2, .spotify, .tidal, .photos, .books …), even
//       ones a future firmware adds.
//    2. is in `reservedAnywhereNames` (e.g. database.ignore).
//    3. contains a fragment in `reservedNameFragments` (e.g. "librespot").
//  …or the FIRST component is in `reservedRootNames` (e.g. Podcasts/).
//
//  Names are compared case-insensitively because FAT and exFAT ignore case
//  ("Podcasts" and "PODCASTS" are the same folder).
//

import Foundation

/// The reserved-items list for one device profile.
struct ReservedItemRules: Hashable, Sendable {

    /// Names reserved only at the card root (files or folders).
    let reservedRootNames: Set<String>

    /// Names reserved at any depth.
    let reservedAnywhereNames: Set<String>

    /// Any name containing one of these (case-insensitive) is reserved.
    let reservedNameFragments: Set<String>

    /// Hidden names the app itself owns and may write to (its state folder).
    let appOwnedHiddenNames: Set<String>

    /// Lowercased copies, computed once for fast comparisons.
    private var lowerRoot: Set<String> { Set(reservedRootNames.map { $0.lowercased() }) }
    private var lowerAnywhere: Set<String> { Set(reservedAnywhereNames.map { $0.lowercased() }) }
    private var lowerOwned: Set<String> { Set(appOwnedHiddenNames.map { $0.lowercased() }) }

    /// Checks whether a card path is reserved.
    ///
    /// - Parameter components: The path relative to the card root, split
    ///   into components, e.g. `["Music", "Adele", "25", "01 Hello.m4a"]`.
    ///   An empty array means the card root itself, which is never reserved
    ///   (but the PathGuard separately refuses to delete the root).
    /// - Returns: `true` if the app must leave this item alone.
    func isReserved(components: [String]) -> Bool {
        guard let first = components.first else { return false }

        // Everything inside the app's own state folder (at the root) belongs
        // to the app: its manifest, temp files, trash (which holds a
        // `database.ignore` marker on purpose), and logs.
        if lowerOwned.contains(first.lowercased()) { return false }

        if lowerRoot.contains(first.lowercased()) { return true }

        for (index, name) in components.enumerated() {
            let lower = name.lowercased()

            // Rule 1: hidden items. The app's own state folder is allowed,
            // but only at the card root (".q2sync" deeper down isn't ours).
            if lower.hasPrefix(".") {
                let isOwnStateFolder = index == 0 && lowerOwned.contains(lower)
                if !isOwnStateFolder { return true }
            }

            // Rule 2: names reserved anywhere.
            if lowerAnywhere.contains(lower) { return true }

            // Rule 3: name fragments.
            if reservedNameFragments.contains(where: { lower.contains($0.lowercased()) }) { return true }
        }
        return false
    }

    /// Convenience for a slash-separated relative path like `"Music/A/B.mp3"`.
    ///
    /// - Parameter relativePath: Path relative to the card root.
    /// - Returns: `true` if reserved.
    func isReserved(relativePath: String) -> Bool {
        isReserved(components: relativePath.split(separator: "/").map(String.init))
    }
}
