//
//  Track.swift
//  Q2-Sync › Core › Models
//
//  PURPOSE
//  A `Track` is our own, simple, read-only description of one song in the
//  Apple Music library.
//
//  HOW IT FITS
//  The Library layer (see `ITunesLibrarySource`) reads Apple's
//  `ITLibMediaItem` objects and immediately converts each one into a
//  `Track`. Everything else in the app (selection, sync planning, playlist
//  writing) works only with `Track` values and never with Apple's objects.
//
//  Why copy the data instead of using Apple's objects directly?
//  • Safety: our code can never accidentally call anything on the library.
//  • Concurrency: `Track` is a plain value (a `struct`) that is `Sendable`,
//    meaning Swift can prove it's safe to pass between threads.
//  • Testing: tests can create `Track`s by hand without a real library.
//

import Foundation

/// The library's stable identifier for a track or playlist.
///
/// Apple Music gives every item a 64-bit "persistent ID". We store it as a
/// 16-digit uppercase hexadecimal string (the same style Apple uses in its
/// XML exports), e.g. `"1A2B3C4D5E6F7081"`.
typealias PersistentID = String

/// Whether a track's audio file can actually be copied to the card.
///
/// Only `.available` tracks are ever copied. Everything else is reported in
/// the sync report as "skipped", with this value explaining why.
enum TrackAvailability: String, Codable, Sendable, CaseIterable {
    /// A local, unprotected file that exists on disk. Safe to copy.
    case available

    /// The song lives only in iCloud / Apple Music streaming. We never
    /// trigger a download, so it's skipped.
    case cloudOnly

    /// Protected by DRM (old iTunes Store purchases or Apple Music
    /// downloads). The Q2 can't play these, so they're skipped.
    case drmProtected

    /// The library says there's a file, but it isn't on disk right now
    /// (for example, an external music drive is disconnected).
    case fileMissing

    /// Not a song at all for our purposes (a stream URL, a video, etc.).
    case unsupported

    /// A short, user-facing explanation for the sync report.
    var reportDescription: String {
        switch self {
        case .available:    return "Available"
        case .cloudOnly:    return "In the cloud only (not downloaded)"
        case .drmProtected: return "Protected (DRM)"
        case .fileMissing:  return "File not found on disk"
        case .unsupported:  return "Not a supported audio file"
        }
    }
}

/// One song from the Apple Music library, copied into a plain value.
///
/// All properties are `let` constants: once read, a `Track` never changes.
/// `Codable` lets us save tracks to JSON (used by test fixtures), and
/// `Hashable`/`Identifiable` let SwiftUI lists and `Set`s work with them.
struct Track: Codable, Hashable, Identifiable, Sendable {

    // MARK: Identity

    /// Apple Music's persistent ID for this track (hex string).
    let id: PersistentID

    // MARK: Tags (the Q2 builds its library from these)

    /// Song title. Never empty: falls back to the file name.
    let title: String

    /// Track artist, e.g. "Paul McCartney & Wings". `nil` if untagged.
    let artist: String?

    /// Album artist, e.g. "Wings". Q2 Pod groups albums by this, so it
    /// matters a lot. `nil` if untagged.
    let albumArtist: String?

    /// Album title. `nil` if untagged.
    let album: String?

    /// Genre name. `nil` if untagged.
    let genre: String?

    /// Track number on its disc (1-based). `0` means "unknown".
    let trackNumber: Int

    /// Disc number (1-based). `0` means "unknown".
    let discNumber: Int

    /// Number of discs in the album. `0` means "unknown".
    let discCount: Int

    /// `true` when the album is marked as a compilation in Music.
    let isCompilation: Bool

    // MARK: File facts

    /// Length in seconds (Apple reports milliseconds; we convert).
    let durationSeconds: Double

    /// File size in bytes, as recorded by the library.
    let fileSize: UInt64

    /// Where the audio file lives on this Mac, if it's a local file.
    /// We only ever *read* from this location.
    let fileURL: URL?

    /// Human-readable file kind from Music, e.g. "MPEG audio file".
    let fileKind: String?

    /// When the file was last modified, according to the library.
    /// Used later to detect changed tracks that need re-copying.
    let modifiedDate: Date?

    /// Whether this track can be copied, and if not, why not.
    let availability: TrackAvailability

    // MARK: Convenience

    /// The name we group this track's album under.
    ///
    /// Mirrors how Q2 Pod groups albums (album artist first). For
    /// compilations without an album artist we use "Various Artists" so
    /// the album isn't split into one album per track artist.
    var effectiveAlbumArtist: String {
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        if isCompilation { return "Various Artists" }
        return artist ?? "Unknown Artist"
    }

    /// The artist name shown in the "Artists" section of the selection UI.
    var displayArtist: String { artist?.nonEmpty ?? "Unknown Artist" }

    /// The album name shown in the UI.
    var displayAlbum: String { album?.nonEmpty ?? "Unknown Album" }

    /// The genre name shown in the UI.
    var displayGenre: String { genre?.nonEmpty ?? "Unknown Genre" }

    /// `true` if this track can be copied to the card.
    var isCopyable: Bool { availability == .available }
}

extension String {
    /// Returns `nil` for an empty or whitespace-only string, otherwise the
    /// string itself. Handy for tag fields that are present-but-blank.
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
