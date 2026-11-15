//
//  SyncSelection.swift
//  Q2-Sync › Core › Models
//
//  PURPOSE
//  What the user ticked for a device: either "entire library", or a set of
//  artists, albums, genres and playlists, like Finder's iPod sync.
//
//  HOW IT FITS
//  Saved per device (inside `KnownDevice`). `SelectionResolver` turns it
//  into the exact list of tracks to sync from a `LibrarySnapshot`.
//
//  WHY KEYS INSTEAD OF TRACK IDS
//  We store what the user *meant* ("all of Radiohead"), not a frozen track
//  list. So when you add a new Radiohead album to Music, the next sync
//  picks it up automatically, just like Finder did for iPods.
//

import Foundation

/// The user's choice of what to sync to one device.
struct SyncSelection: Codable, Hashable, Sendable {

    /// The two modes offered in the UI.
    enum Mode: String, Codable, Sendable {
        /// Every song in the library (and every playlist).
        case entireLibrary
        /// Only the ticked artists, albums, genres and playlists.
        case selectedItems
    }

    /// Which mode is active.
    var mode: Mode = .selectedItems

    /// Ticked artists, as `TrackGroup.id` values (e.g. `"artist:adele"`).
    var artistIDs: Set<String> = []

    /// Ticked albums, as `TrackGroup.id` values (e.g. `"album:adele|25"`).
    var albumIDs: Set<String> = []

    /// Ticked genres, as `TrackGroup.id` values (e.g. `"genre:rock"`).
    var genreIDs: Set<String> = []

    /// Ticked playlists, by playlist persistent ID.
    var playlistIDs: Set<PersistentID> = []

    /// `true` if nothing at all is selected (and not entire-library mode).
    var isEmpty: Bool {
        mode == .selectedItems && artistIDs.isEmpty && albumIDs.isEmpty
            && genreIDs.isEmpty && playlistIDs.isEmpty
    }

    /// Total number of ticked items across all sections.
    var tickedItemCount: Int {
        artistIDs.count + albumIDs.count + genreIDs.count + playlistIDs.count
    }
}
