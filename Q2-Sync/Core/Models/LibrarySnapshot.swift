//
//  LibrarySnapshot.swift
//  Q2-Sync › Core › Models
//
//  PURPOSE
//  A `LibrarySnapshot` is a frozen, read-only picture of the Apple Music
//  library at one moment: every music track, every playlist, and where the
//  media folder is. It also builds the Artist / Album / Genre groupings
//  shown in the selection UI.
//
//  HOW IT FITS
//      ITunesLibrarySource ──reads──▶ LibrarySnapshot ──used by──▶ UI, SyncEngine
//
//  Because a snapshot is an immutable value, the UI can display it while
//  the sync engine plans from it on another thread, with no locking.
//

import Foundation

/// A group of tracks shown as one row in the Artists, Albums or Genres
/// section (for example "Radiohead" or "OK Computer — Radiohead").
struct TrackGroup: Hashable, Identifiable, Sendable {

    /// Stable key used for selection, e.g. `"album:radiohead|ok computer"`.
    let id: String

    /// Main text for the row, e.g. "OK Computer".
    let title: String

    /// Secondary text, e.g. the album artist. `nil` when not needed.
    let subtitle: String?

    /// Track IDs in this group, in a sensible play order.
    let trackIDs: [PersistentID]
}

/// An immutable copy of the music part of the Apple Music library.
struct LibrarySnapshot: Sendable {

    /// Every music track (songs only — no videos, podcasts, etc.).
    let tracks: [Track]

    /// Every user-visible playlist and playlist folder.
    let playlists: [Playlist]

    /// The "Music Media" folder Apple Music manages, if known.
    /// Used by the "Mac looks empty" safety check.
    let mediaFolderURL: URL?

    /// When this snapshot was taken.
    let loadedAt: Date

    /// Fast lookup from track ID to track, built once in `init`.
    let tracksByID: [PersistentID: Track]

    /// Creates a snapshot and builds the ID lookup table.
    ///
    /// - Parameters:
    ///   - tracks: All music tracks.
    ///   - playlists: All playlists (regular, smart and folders).
    ///   - mediaFolderURL: The library's media folder, if known.
    ///   - loadedAt: Timestamp; defaults to now.
    init(tracks: [Track], playlists: [Playlist], mediaFolderURL: URL?, loadedAt: Date = .now) {
        self.tracks = tracks
        self.playlists = playlists
        self.mediaFolderURL = mediaFolderURL
        self.loadedAt = loadedAt
        // `uniquingKeysWith` keeps the first track if an ID ever repeats,
        // instead of crashing (Dictionary(uniqueKeysWithValues:) would trap).
        self.tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Counts

    /// How many tracks fall into each availability category.
    /// Used for the status line ("9,812 songs · 140 cloud-only · …").
    var availabilityCounts: [TrackAvailability: Int] {
        Dictionary(grouping: tracks, by: \.availability).mapValues(\.count)
    }

    // MARK: - Groupings for the selection UI

    /// One group per track artist, sorted like the Q2 sorts (ignoring a
    /// leading "The", "A" or "An").
    var artistGroups: [TrackGroup] {
        makeGroups(
            key: { $0.displayArtist },
            title: { $0.displayArtist },
            subtitle: { _ in nil },
            prefix: "artist"
        )
    }

    /// One group per album, keyed by album name plus album artist (the
    /// same rule Q2 Pod uses), sorted by album title.
    var albumGroups: [TrackGroup] {
        makeGroups(
            key: { "\($0.effectiveAlbumArtist)|\($0.displayAlbum)" },
            title: { $0.displayAlbum },
            subtitle: { $0.effectiveAlbumArtist },
            prefix: "album"
        )
    }

    /// One group per genre, sorted alphabetically.
    var genreGroups: [TrackGroup] {
        makeGroups(
            key: { $0.displayGenre },
            title: { $0.displayGenre },
            subtitle: { _ in nil },
            prefix: "genre"
        )
    }

    /// Looks up the tracks for a list of IDs, skipping unknown IDs.
    ///
    /// - Parameter ids: Track IDs, e.g. from a playlist or group.
    /// - Returns: The matching tracks, in the same order.
    func tracks(for ids: [PersistentID]) -> [Track] {
        ids.compactMap { tracksByID[$0] }
    }

    // MARK: - Private helpers

    /// Shared grouping logic for artists, albums and genres.
    ///
    /// Tracks are grouped case-insensitively (so "Beatles" and "beatles"
    /// land together), each group's tracks are ordered by disc then track
    /// number, and groups are sorted with `SortKey.compare`.
    ///
    /// - Parameters:
    ///   - key: Produces the grouping key for a track.
    ///   - title: Produces the row title from a group's first track.
    ///   - subtitle: Produces the optional row subtitle.
    ///   - prefix: Namespace for the group ID ("artist", "album", "genre").
    /// - Returns: Sorted groups.
    private func makeGroups(
        key: (Track) -> String,
        title: (Track) -> String,
        subtitle: (Track) -> String?,
        prefix: String
    ) -> [TrackGroup] {
        let grouped = Dictionary(grouping: tracks) { key($0).lowercased() }

        let groups = grouped.map { (groupKey, members) -> TrackGroup in
            let ordered = members.sorted(by: Self.playOrder)
            let first = ordered[0] // Dictionary(grouping:) never makes empty groups.
            return TrackGroup(
                id: "\(prefix):\(groupKey)",
                title: title(first),
                subtitle: subtitle(first),
                trackIDs: ordered.map(\.id)
            )
        }
        return groups.sorted { SortKey.compare($0.title, $1.title) }
    }

    /// Orders tracks the way an album plays: disc, then track, then title.
    private static func playOrder(_ a: Track, _ b: Track) -> Bool {
        if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
        if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}

/// Sorting rules that match how the Q2 (Q2 Pod) sorts names.
enum SortKey {

    /// Articles ignored at the start of a name when sorting.
    private static let leadingArticles = ["the ", "a ", "an "]

    /// Returns the name with a leading "The ", "A " or "An " removed,
    /// so "The Beatles" sorts under B.
    ///
    /// - Parameter name: A display name.
    /// - Returns: The name to sort by.
    static func sortableName(_ name: String) -> String {
        let lower = name.lowercased()
        for article in leadingArticles where lower.hasPrefix(article) && lower.count > article.count {
            return String(name.dropFirst(article.count))
        }
        return name
    }

    /// `true` if `a` should sort before `b`, ignoring leading articles and
    /// using Finder-style ("localized standard") comparison so "Track 2"
    /// sorts before "Track 10".
    static func compare(_ a: String, _ b: String) -> Bool {
        sortableName(a).localizedStandardCompare(sortableName(b)) == .orderedAscending
    }
}
