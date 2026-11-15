//
//  SelectionResolver.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Turns a `SyncSelection` ("these artists, albums, genres, playlists")
//  into the concrete set of tracks and playlists to sync, plus the list of
//  tracks that will be skipped and why.
//
//  HOW IT FITS
//      SyncSelection + LibrarySnapshot ──resolve──▶ ResolvedSelection
//            ──▶ shown as the selection summary in the UI
//            ──▶ input to the sync planner
//
//  RULE
//  The tracks to sync are the UNION of everything ticked: a song is
//  included if its artist OR its album OR its genre OR any playlist it's
//  in is ticked. Only `available` tracks are copied; cloud-only, DRM and
//  missing files are listed as skipped and never downloaded.
//

import Foundation

/// The concrete result of resolving a selection against a library.
struct ResolvedSelection: Sendable {

    /// Tracks that will be copied, without duplicates, in a stable order
    /// (album artist, album, disc, track).
    let tracksToSync: [Track]

    /// Selected tracks that can't be copied, with the reason in each
    /// track's `availability`.
    let skippedTracks: [Track]

    /// Playlists to write to the card (folders excluded).
    let playlists: [Playlist]

    /// Ticked items that no longer exist in the library (for example an
    /// album you deleted from Music). They're ignored, never an error.
    let missingSelectionCount: Int

    /// Total size of `tracksToSync`, in bytes, from the library's records.
    var totalBytes: UInt64 { tracksToSync.reduce(0) { $0 + $1.fileSize } }

    /// Skipped tracks counted by reason, for the summary line.
    var skippedCounts: [TrackAvailability: Int] {
        Dictionary(grouping: skippedTracks, by: \.availability).mapValues(\.count)
    }
}

/// Resolves selections. A namespace (`enum` with no cases) for pure functions.
enum SelectionResolver {

    /// Resolves a selection against a library snapshot.
    ///
    /// - Parameters:
    ///   - selection: What the user ticked.
    ///   - snapshot: The current library.
    /// - Returns: Tracks to sync, tracks skipped, and playlists.
    /// - Side effects: None. Pure computation.
    static func resolve(_ selection: SyncSelection, in snapshot: LibrarySnapshot) -> ResolvedSelection {
        let userPlaylists = snapshot.playlists.filter { $0.kind != .folder }

        // Step 1: work out which track IDs are selected, and which playlists.
        var selectedIDs = Set<PersistentID>()
        var playlists: [Playlist] = []
        var missing = 0

        switch selection.mode {
        case .entireLibrary:
            selectedIDs = Set(snapshot.tracks.map(\.id))
            playlists = userPlaylists

        case .selectedItems:
            // Artists, albums and genres share the same lookup approach.
            let sections: [(ids: Set<String>, groups: [TrackGroup])] = [
                (selection.artistIDs, snapshot.artistGroups),
                (selection.albumIDs, snapshot.albumGroups),
                (selection.genreIDs, snapshot.genreGroups),
            ]
            for section in sections where !section.ids.isEmpty {
                let groupsByID = Dictionary(section.groups.map { ($0.id, $0) },
                                            uniquingKeysWith: { first, _ in first })
                for id in section.ids {
                    if let group = groupsByID[id] {
                        selectedIDs.formUnion(group.trackIDs)
                    } else {
                        missing += 1
                    }
                }
            }

            let playlistsByID = Dictionary(userPlaylists.map { ($0.id, $0) },
                                           uniquingKeysWith: { first, _ in first })
            for id in selection.playlistIDs {
                if let playlist = playlistsByID[id] {
                    playlists.append(playlist)
                    selectedIDs.formUnion(playlist.trackIDs)
                } else {
                    missing += 1
                }
            }
            playlists.sort { SortKey.compare($0.name, $1.name) }
        }

        // Step 2: split into copyable and skipped, in a stable order.
        let selectedTracks = snapshot.tracks
            .filter { selectedIDs.contains($0.id) }
            .sorted(by: libraryOrder)

        return ResolvedSelection(
            tracksToSync: selectedTracks.filter(\.isCopyable),
            skippedTracks: selectedTracks.filter { !$0.isCopyable },
            playlists: playlists,
            missingSelectionCount: missing
        )
    }

    /// Orders tracks by album artist, album, disc, track, then title, so the
    /// copy runs album by album (nicer progress, and partial syncs leave
    /// whole albums on the card).
    private static func libraryOrder(_ a: Track, _ b: Track) -> Bool {
        if a.effectiveAlbumArtist != b.effectiveAlbumArtist {
            return SortKey.compare(a.effectiveAlbumArtist, b.effectiveAlbumArtist)
        }
        if a.displayAlbum != b.displayAlbum { return SortKey.compare(a.displayAlbum, b.displayAlbum) }
        if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
        if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
        if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
        return a.id < b.id
    }
}
