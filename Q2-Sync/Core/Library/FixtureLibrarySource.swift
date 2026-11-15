//
//  FixtureLibrarySource.swift
//  Q2-Sync › Core › Library
//
//  PURPOSE
//  A fake music library for unit tests and SwiftUI previews.
//
//  HOW IT FITS
//  It conforms to the same `LibrarySource` protocol as the real
//  `ITunesLibrarySource`, so any code that accepts a `LibrarySource` can be
//  tested without touching the real Apple Music library (a project safety
//  rule). Tracks can be given directly in code, or loaded from a JSON file.
//

import Foundation

/// A `LibrarySource` backed by hand-made data instead of Apple Music.
struct FixtureLibrarySource: LibrarySource {

    /// The snapshot returned by `loadSnapshot()`.
    private let snapshot: LibrarySnapshot

    /// Creates a fixture from tracks and playlists built in code.
    ///
    /// - Parameters:
    ///   - tracks: Fake tracks. Their `fileURL`s should point at temporary
    ///     files (or nowhere) — never at the real Music folder.
    ///   - playlists: Fake playlists.
    ///   - mediaFolderURL: A fake media folder, usually a temp directory.
    init(tracks: [Track], playlists: [Playlist] = [], mediaFolderURL: URL? = nil) {
        self.snapshot = LibrarySnapshot(tracks: tracks, playlists: playlists, mediaFolderURL: mediaFolderURL)
    }

    /// The on-disk JSON format for a fixture library.
    struct FileFormat: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
        var mediaFolderURL: URL?
    }

    /// Creates a fixture by decoding a JSON file in `FileFormat`.
    ///
    /// - Parameter url: The JSON file to read.
    /// - Throws: `LibraryError.fixtureUnreadable` if reading or decoding fails.
    init(contentsOf url: URL) throws {
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(FileFormat.self, from: data)
            self.init(tracks: file.tracks, playlists: file.playlists, mediaFolderURL: file.mediaFolderURL)
        } catch {
            throw LibraryError.fixtureUnreadable(underlying: error.localizedDescription)
        }
    }

    /// Returns the fixture's snapshot immediately.
    func loadSnapshot() async throws -> LibrarySnapshot { snapshot }
}

// MARK: - Sample data for previews

extension FixtureLibrarySource {

    /// A tiny made-up library used by SwiftUI previews. File URLs point to
    /// a non-existent temp path, so nothing real is ever referenced.
    static let preview: FixtureLibrarySource = {
        let fakeFolder = URL(filePath: NSTemporaryDirectory()).appending(path: "Q2SyncPreview")

        /// Builds one sample track. A local helper keeps the list readable.
        func track(_ id: Int, _ title: String, _ artist: String, _ album: String,
                   _ genre: String, _ number: Int,
                   _ availability: TrackAvailability = .available) -> Track {
            Track(
                id: String(format: "%016X", id),
                title: title, artist: artist, albumArtist: artist, album: album,
                genre: genre, trackNumber: number, discNumber: 1, discCount: 1,
                isCompilation: false, durationSeconds: 200, fileSize: 6_000_000,
                fileURL: fakeFolder.appending(path: "\(artist)/\(album)/\(number) \(title).m4a"),
                fileKind: "AAC audio file", modifiedDate: nil, availability: availability
            )
        }

        let tracks = [
            track(1, "Opening Theme", "The Sample Band", "First Light", "Rock", 1),
            track(2, "Second Song", "The Sample Band", "First Light", "Rock", 2),
            track(3, "Cloud Tune", "Demo Artist", "Up There", "Pop", 1, .cloudOnly),
            track(4, "Protected", "Demo Artist", "Up There", "Pop", 2, .drmProtected),
            track(5, "Quiet Piece", "An Example Trio", "Evenings", "Jazz", 1),
        ]
        let playlists = [
            Playlist(id: "00000000000000AA", name: "Favourites", kind: .regular,
                     parentID: nil, trackIDs: [tracks[0].id, tracks[4].id]),
            Playlist(id: "00000000000000BB", name: "Recently Rocked", kind: .smart,
                     parentID: nil, trackIDs: [tracks[1].id]),
        ]
        return FixtureLibrarySource(tracks: tracks, playlists: playlists, mediaFolderURL: fakeFolder)
    }()
}
