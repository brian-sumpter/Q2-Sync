//
//  PlaylistWriter.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Turns Apple Music playlists into `.m3u` files the Q2 can import, and
//  decides which playlist files to write, keep or remove on the card.
//
//  WHAT THE Q2 EXPECTS (from Q2 Pod's user guide, release 1.8.5)
//  • Playlists are `.m3u` files in `_explaylist_data/` at the card root.
//    Stock firmware uses the same folder.
//  • One song per line, as `/mnt/mmc/Music/…` (or `A:\Music\…`).
//  • Comment lines must contain "#EXT" (`#EXTM3U`, `#EXTINF`); any other
//    line starting with "#" shows up as a broken song.
//  • The playlist's name on the Q2 is the file name without `.m3u`, at
//    most 63 bytes. Importing replaces a playlist with the same name.
//  • At most 100 playlists.
//  • The user imports them on the Q2: Library → Playlists → Import.
//  These details are UNVERIFIED on a real Q2 until the format check in
//  docs/DEVICE_CHECKS.md is done; they live in `PlaylistFormat` so they're
//  easy to change.
//
//  EXAMPLE OUTPUT
//      #EXTM3U
//      #EXTINF:357,Steel Beans - Too On
//      /mnt/mmc/Music/Steel Beans/Steel Beans/05 Too On.m4a
//
//  OWNERSHIP
//  The manifest records every playlist file Q2 Sync wrote. Only those are
//  ever replaced or removed. Playlists you put in `_explaylist_data/`
//  yourself (and their pictures) are never touched; a name clash gives
//  ours a " (2)" name instead.
//

import Foundation

/// A playlist file to write.
struct PlannedPlaylist: Sendable, Hashable, Identifiable {
    let playlist: Playlist
    /// Card path, e.g. `"_explaylist_data/Road Trip.m3u"`.
    let path: CardPath
    /// `true` if the name had to be shortened or changed for the card.
    let nameWasChanged: Bool
    var id: PersistentID { playlist.id }

    /// The name the playlist will have on the Q2 (file name without extension).
    var nameOnDevice: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

/// A playlist file Q2 Sync wrote earlier that's no longer wanted.
struct PlaylistRemoval: Sendable, Hashable, Identifiable {
    let playlistID: PersistentID
    let path: CardPath
    var id: PersistentID { playlistID }
}

/// What will happen to playlists in a sync.
struct PlaylistPlan: Sendable {
    var writes: [PlannedPlaylist] = []
    var removals: [PlaylistRemoval] = []
    /// Selected playlists left out because of the device's playlist limit.
    var overLimit: [Playlist] = []
    /// `.m3u` files in the playlist folder that Q2 Sync didn't write.
    var otherPlaylistFiles = 0
}

/// The result of rendering one playlist.
struct RenderedPlaylist: Sendable {
    /// The file's bytes.
    let data: Data
    /// Songs written into the playlist.
    let songCount: Int
    /// Songs left out because they aren't on the card (e.g. cloud-only).
    let missingCount: Int
}

/// Plans and renders playlist files.
enum PlaylistWriter {

    // MARK: - Planning

    /// Decides which playlist files to write and remove.
    ///
    /// - Parameters:
    ///   - playlists: Selected playlists (folders already excluded).
    ///   - manifest: Records which playlist files Q2 Sync wrote before.
    ///   - folderFiles: Files now in the playlist folder, keyed by `caseKey`.
    ///   - profile: Folder name, extension, limits.
    /// - Returns: The playlist plan.
    static func plan(playlists: [Playlist], manifest: SyncManifest,
                     folderFiles: [String: CardFile], profile: DeviceProfile) -> PlaylistPlan {
        var result = PlaylistPlan()
        let ownedKeys = Set(manifest.playlistFiles.values.map(CardLayout.caseKey))
        let ext = profile.playlistFormat.fileExtension.lowercased()
        result.otherPlaylistFiles = folderFiles.filter { key, _ in
            key.hasSuffix(".\(ext)") && !ownedKeys.contains(key)
        }.count

        // Sorted by name so the 100-playlist cut-off is predictable.
        let sorted = playlists.sorted { SortKey.compare($0.name, $1.name) }
        let kept = Array(sorted.prefix(profile.maximumPlaylists))
        result.overLimit = Array(sorted.dropFirst(profile.maximumPlaylists))

        // Names already used: every file in the folder (ours or not), so a
        // user's own playlist is never overwritten.
        var taken = Set(folderFiles.keys)

        // Pass 1: playlists that already have a file keep its name if it
        // still fits their (possibly renamed) playlist name.
        var assigned: [PersistentID: CardPath] = [:]
        for playlist in kept {
            guard let existing = manifest.playlistFiles[playlist.id] else { continue }
            let preferred = preferredPath(for: playlist, profile: profile)
            if isSameOrVariant(existing, of: preferred, profile: profile) {
                assigned[playlist.id] = existing
            }
        }
        // Pass 2: the rest get the first free name.
        for playlist in kept where assigned[playlist.id] == nil {
            // Our own previous file for this playlist doesn't block it.
            var available = taken
            if let old = manifest.playlistFiles[playlist.id] { available.remove(CardLayout.caseKey(old)) }
            let preferred = preferredPath(for: playlist, profile: profile)
            let path = firstFreePath(preferred, taken: available.union(assigned.values.map(CardLayout.caseKey)),
                                     profile: profile)
            assigned[playlist.id] = path
            taken.insert(CardLayout.caseKey(path))
        }

        for playlist in kept {
            guard let path = assigned[playlist.id] else { continue }
            let plain = "\(profile.playlistFolderName)/\(playlist.name).\(profile.playlistFormat.fileExtension)"
            result.writes.append(PlannedPlaylist(playlist: playlist, path: path,
                                                 nameWasChanged: path != plain))
        }

        // Our files for playlists no longer written are removed, along
        // with our old file when a playlist got a new name.
        let writtenKeys = Set(result.writes.map { CardLayout.caseKey($0.path) })
        for (id, path) in manifest.playlistFiles where !writtenKeys.contains(CardLayout.caseKey(path)) {
            if folderFiles[CardLayout.caseKey(path)] != nil {
                result.removals.append(PlaylistRemoval(playlistID: id, path: path))
            }
        }
        result.removals.sort { $0.path < $1.path }
        return result
    }

    /// The preferred card path for a playlist, e.g.
    /// `"_explaylist_data/Road Trip.m3u"`, with the name cleaned for FAT and
    /// shortened to the device's byte limit.
    static func preferredPath(for playlist: Playlist, profile: DeviceProfile) -> CardPath {
        let name = FilenameSanitizer.sanitizeComponent(playlist.name, fallback: "Playlist",
                                                       maximumBytes: profile.maximumPlaylistNameBytes)
        return "\(profile.playlistFolderName)/\(name).\(profile.playlistFormat.fileExtension)"
    }

    /// The Nth numbered variant, keeping the name within the byte limit:
    /// "Road Trip.m3u" → "Road Trip (2).m3u".
    static func variant(of path: CardPath, number: Int, profile: DeviceProfile) -> CardPath {
        let ext = profile.playlistFormat.fileExtension
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let suffix = " (\(number))"
        let base = FilenameSanitizer.truncate(name, maximumBytes: profile.maximumPlaylistNameBytes - suffix.utf8.count)
        return "\(profile.playlistFolderName)/\(base)\(suffix).\(ext)"
    }

    /// `true` if `path` is `preferred` or one of its numbered variants.
    private static func isSameOrVariant(_ path: CardPath, of preferred: CardPath, profile: DeviceProfile) -> Bool {
        let key = CardLayout.caseKey(path)
        if key == CardLayout.caseKey(preferred) { return true }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let range = name.range(of: #" \((\d+)\)$"#, options: .regularExpression),
              let number = Int(name[range].filter(\.isNumber)), number >= 2 else { return false }
        return key == CardLayout.caseKey(variant(of: preferred, number: number, profile: profile))
    }

    /// The preferred path if free, otherwise the first free variant.
    private static func firstFreePath(_ preferred: CardPath, taken: Set<String>, profile: DeviceProfile) -> CardPath {
        if !taken.contains(CardLayout.caseKey(preferred)) { return preferred }
        var number = 2
        while taken.contains(CardLayout.caseKey(variant(of: preferred, number: number, profile: profile))) {
            number += 1
        }
        return variant(of: preferred, number: number, profile: profile)
    }

    /// When a sync changes no songs, drops playlist writes whose file on
    /// the card already has exactly the right contents, so an unchanged
    /// card shows "Already Up to Date".
    ///
    /// - Parameters:
    ///   - plan: The sync plan to adjust.
    ///   - manifest: The current manifest (accurate when no songs change).
    ///   - profile: Format details.
    ///   - read: Reads a card file's bytes, or `nil` if it doesn't exist.
    static func dropUnchangedWrites(in plan: inout SyncPlan, manifest: SyncManifest, profile: DeviceProfile,
                                    read: (CardPath) -> Data?) {
        let songsChange = !(plan.copies.isEmpty && plan.moves.isEmpty && plan.removals.isEmpty
            && plan.adoptions.isEmpty && plan.forgottenEntries.isEmpty)
        guard !songsChange else { return }
        plan.playlistPlan.writes.removeAll { planned in
            guard manifest.playlistFiles[planned.playlist.id] == planned.path else { return false }
            let rendered = render(planned.playlist, entries: manifest.entries, tracks: plan.tracksByID, profile: profile)
            return read(planned.path) == rendered.data
        }
    }

    // MARK: - Rendering

    /// Writes a playlist as M3U text.
    ///
    /// Only songs that are actually on the card (in the manifest) are
    /// included, in the playlist's order, duplicates kept.
    ///
    /// - Parameters:
    ///   - playlist: The playlist.
    ///   - entries: The manifest's songs on the card, by track ID.
    ///   - tracks: Library tracks by ID, for durations and names.
    ///   - profile: Mount point and format.
    /// - Returns: The file contents and counts.
    static func render(_ playlist: Playlist, entries: [PersistentID: SyncManifest.Entry],
                       tracks: [PersistentID: Track], profile: DeviceProfile) -> RenderedPlaylist {
        let format = profile.playlistFormat
        var lines: [String] = []
        if format.includesExtendedInfo { lines.append("#EXTM3U") }

        var songs = 0
        var missing = 0
        for id in playlist.trackIDs {
            guard let entry = entries[id] else { missing += 1; continue }
            if format.includesExtendedInfo {
                let track = tracks[id]
                let seconds = Int((track?.durationSeconds ?? 0).rounded())
                let artist = track?.artist ?? entry.artist
                let title = track?.title ?? entry.title
                let label = [artist, title].compactMap { $0 }.joined(separator: " - ")
                lines.append("#EXTINF:\(seconds),\(singleLine(label))")
            }
            lines.append(devicePath(for: entry.path, style: format.pathStyle))
            songs += 1
        }

        let text = lines.map { $0 + format.lineEnding }.joined()
        var data = Data()
        if format.includesByteOrderMark { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(text.precomposedStringWithCanonicalMapping.utf8))
        return RenderedPlaylist(data: data, songCount: songs, missingCount: missing)
    }

    /// A card path as the Q2 sees it, in the chosen style.
    static func devicePath(for path: CardPath, style: PlaylistPathStyle) -> String {
        switch style {
        case .absoluteDevicePath(let mountPoint):
            return "\(mountPoint)/\(path)"
        case .windowsDrive(let letter):
            return "\(letter):\\" + path.replacingOccurrences(of: "/", with: "\\")
        }
    }

    /// Removes line breaks so a title can't start a new (broken) line.
    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}
