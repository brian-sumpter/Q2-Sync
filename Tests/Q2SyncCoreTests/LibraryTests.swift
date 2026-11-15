//
//  LibraryTests.swift
//  Q2-Sync › Tests
//
//  PURPOSE
//  Unit tests for the library models, groupings, sorting and the
//  "Mac looks empty" health check.
//
//  SAFETY
//  These tests use only `FixtureLibrarySource` and temporary folders.
//  They never touch the real Apple Music library or ~/Music.
//
//  These use Swift Testing (`import Testing`): each `@Test` function is a
//  test, and `#expect(...)` checks a condition and reports a readable
//  failure if it's false.
//

import Foundation
import Testing
@testable import Q2SyncCore

/// Builds a test track with sensible defaults; override only what matters.
func makeTrack(
    id: String,
    title: String = "Song",
    artist: String? = "Artist",
    albumArtist: String? = nil,
    album: String? = "Album",
    genre: String? = "Rock",
    track: Int = 1,
    disc: Int = 1,
    compilation: Bool = false,
    availability: TrackAvailability = .available
) -> Track {
    Track(
        id: id, title: title, artist: artist, albumArtist: albumArtist, album: album,
        genre: genre, trackNumber: track, discNumber: disc, discCount: 1,
        isCompilation: compilation, durationSeconds: 180, fileSize: 1_000,
        fileURL: nil, fileKind: nil, modifiedDate: nil, availability: availability
    )
}

/// Creates a fresh, empty temporary folder for a test.
func makeTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "Q2SyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Library snapshot and groupings")
struct LibrarySnapshotTests {

    @Test("Albums group by album artist + album name, ordered by disc then track")
    func albumGrouping() {
        let snapshot = LibrarySnapshot(tracks: [
            makeTrack(id: "3", title: "C", artist: "Guest", albumArtist: "Band", album: "LP", track: 1, disc: 2),
            makeTrack(id: "1", title: "A", artist: "Band", albumArtist: "Band", album: "LP", track: 2, disc: 1),
            makeTrack(id: "2", title: "B", artist: "Band", albumArtist: "Band", album: "LP", track: 1, disc: 1),
            makeTrack(id: "4", title: "D", artist: "Other", albumArtist: "Other", album: "LP"),
        ], playlists: [], mediaFolderURL: nil)

        let albums = snapshot.albumGroups
        #expect(albums.count == 2, "Same album name with different album artists must stay separate")
        let band = albums.first { $0.subtitle == "Band" }
        #expect(band?.trackIDs == ["2", "1", "3"])
    }

    @Test("Compilations without an album artist group under Various Artists")
    func compilationGrouping() {
        let snapshot = LibrarySnapshot(tracks: [
            makeTrack(id: "1", artist: "X", album: "Hits", compilation: true),
            makeTrack(id: "2", artist: "Y", album: "Hits", compilation: true),
        ], playlists: [], mediaFolderURL: nil)
        #expect(snapshot.albumGroups.count == 1)
        #expect(snapshot.albumGroups.first?.subtitle == "Various Artists")
    }

    @Test("Artists and genres group case-insensitively; untagged gets a placeholder")
    func artistAndGenreGrouping() {
        let snapshot = LibrarySnapshot(tracks: [
            makeTrack(id: "1", artist: "beatles", genre: "rock"),
            makeTrack(id: "2", artist: "Beatles", genre: "Rock"),
            makeTrack(id: "3", artist: nil, genre: nil),
        ], playlists: [], mediaFolderURL: nil)
        #expect(snapshot.artistGroups.count == 2)
        #expect(snapshot.artistGroups.contains { $0.title == "Unknown Artist" })
        #expect(snapshot.genreGroups.count == 2)
    }

    @Test("Sorting ignores a leading The/A/An and uses natural number order")
    func sorting() {
        let names = ["The Zombies", "Abba", "A Tribe Called Quest", "Track 10", "Track 2", "An Horse"]
        let sorted = names.sorted(by: SortKey.compare)
        #expect(sorted == ["Abba", "An Horse", "Track 2", "Track 10", "A Tribe Called Quest", "The Zombies"])
        // A name that is only the article is left alone.
        #expect(SortKey.sortableName("The ") == "The ")
    }

    @Test("Duplicate track IDs don't crash the lookup table")
    func duplicateIDs() {
        let snapshot = LibrarySnapshot(tracks: [makeTrack(id: "1", title: "First"), makeTrack(id: "1", title: "Second")],
                                       playlists: [], mediaFolderURL: nil)
        #expect(snapshot.tracksByID["1"]?.title == "First")
    }

    @Test("Fixture source round-trips through JSON")
    func fixtureJSON() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = FixtureLibrarySource.FileFormat(
            tracks: [makeTrack(id: "1")],
            playlists: [Playlist(id: "P", name: "Mix", kind: .regular, parentID: nil, trackIDs: ["1"])],
            mediaFolderURL: folder
        )
        let jsonURL = folder.appending(path: "library.json")
        try JSONEncoder().encode(file).write(to: jsonURL)

        let snapshot = try await FixtureLibrarySource(contentsOf: jsonURL).loadSnapshot()
        #expect(snapshot.tracks.count == 1)
        #expect(snapshot.playlists.first?.trackIDs == ["1"])
    }

    @Test("A broken fixture file throws a readable error")
    func fixtureBroken() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let jsonURL = folder.appending(path: "bad.json")
        try Data("not json".utf8).write(to: jsonURL)
        #expect(throws: LibraryError.self) { try FixtureLibrarySource(contentsOf: jsonURL) }
    }
}

@Suite("Mac looks empty guard")
struct LibraryHealthTests {

    @Test("An empty library is unsafe")
    func emptyLibrary() {
        let snapshot = LibrarySnapshot(tracks: [], playlists: [], mediaFolderURL: nil)
        #expect(!LibraryHealthCheck.evaluate(snapshot).isHealthy)
    }

    @Test("A missing media folder (disconnected drive) is unsafe")
    func missingMediaFolder() {
        let gone = URL(filePath: "/Volumes/Q2SyncTestDriveThatDoesNotExist/Music")
        let snapshot = LibrarySnapshot(tracks: [makeTrack(id: "1")], playlists: [], mediaFolderURL: gone)
        #expect(!LibraryHealthCheck.evaluate(snapshot).isHealthy)
    }

    @Test("Many missing files is unsafe; a few is fine")
    func missingFiles() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var tracks = (0..<95).map { makeTrack(id: "ok\($0)") }
        tracks += (0..<5).map { makeTrack(id: "gone\($0)", availability: .fileMissing) }
        let few = LibrarySnapshot(tracks: tracks, playlists: [], mediaFolderURL: folder)
        #expect(LibraryHealthCheck.evaluate(few).isHealthy)

        tracks += (0..<20).map { makeTrack(id: "more\($0)", availability: .fileMissing) }
        let many = LibrarySnapshot(tracks: tracks, playlists: [], mediaFolderURL: folder)
        #expect(!LibraryHealthCheck.evaluate(many).isHealthy)
    }

    @Test("Cloud-only and DRM tracks don't count as missing files")
    func cloudAndDRMIgnored() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tracks = [makeTrack(id: "1")]
            + (0..<50).map { makeTrack(id: "c\($0)", availability: .cloudOnly) }
            + (0..<50).map { makeTrack(id: "d\($0)", availability: .drmProtected) }
        let snapshot = LibrarySnapshot(tracks: tracks, playlists: [], mediaFolderURL: folder)
        #expect(LibraryHealthCheck.evaluate(snapshot).isHealthy)
    }
}
