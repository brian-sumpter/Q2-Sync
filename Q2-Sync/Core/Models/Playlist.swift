//
//  Playlist.swift
//  Q2-Sync › Core › Models
//
//  PURPOSE
//  A `Playlist` is our own read-only copy of one Apple Music playlist:
//  its name, kind, and the ordered list of track IDs it contains.
//
//  HOW IT FITS
//  Created by the Library layer, shown in the "Playlists" selection
//  section, and later turned into an `.m3u` file on the card by the
//  playlist writer. Smart playlists are included as a snapshot of their
//  *current* contents (we never evaluate smart rules ourselves).
//

import Foundation

/// The kinds of playlists we care about.
enum PlaylistKind: String, Codable, Sendable {
    /// A normal playlist the user built by hand.
    case regular
    /// A smart playlist; we use its current contents.
    case smart
    /// A folder that only groups other playlists. Has no tracks itself.
    case folder
}

/// One Apple Music playlist, copied into a plain value.
struct Playlist: Codable, Hashable, Identifiable, Sendable {

    /// Apple Music's persistent ID for this playlist (hex string).
    let id: PersistentID

    /// The name shown in Music, e.g. "Road Trip".
    let name: String

    /// Regular, smart or folder.
    let kind: PlaylistKind

    /// The ID of the folder this playlist sits in, if any.
    let parentID: PersistentID?

    /// Track IDs in playlist order. May contain duplicates, because a
    /// playlist can contain the same song twice.
    let trackIDs: [PersistentID]

    /// SF Symbol name used to draw this playlist in the UI.
    var symbolName: String {
        switch kind {
        case .regular: return "music.note.list"
        case .smart:   return "gearshape"
        case .folder:  return "folder"
        }
    }
}
