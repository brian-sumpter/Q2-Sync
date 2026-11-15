//
//  PathGuardTests.swift
//  Q2-Sync › Tests
//
//  PURPOSE
//  Tries hard to trick the PathGuard: path traversal, symlinks, reserved
//  items, the wrong card, internal disks, protected folders. Every attempt
//  must be refused.
//
//  SAFETY
//  The "card" is a temporary folder; the guard is told (via an injected
//  volume reader) that it's a removable exFAT card. The "protected" Music
//  folder in these tests is also a temp folder (`fakeHomeMusic`), so the
//  real ~/Music is never touched, not even to look at it.
//

import Foundation
import Testing
@testable import Q2SyncCore

/// A stand-in for ~/Music used by every guard in the tests.
let fakeHomeMusic = FileManager.default.temporaryDirectory.appending(path: "Q2SyncTests-FakeHomeMusic")

/// A temp folder pretending to be a Q2 card, plus a guard and file system for it.
struct TestCard {
    let root: URL
    let pathGuard: PathGuard
    var fileSystem: CardFileSystem { CardFileSystem(pathGuard: pathGuard) }

    static let uuid = "TEST-CARD-UUID"

    /// Creates the card. `volume` lets a test simulate other kinds of disk.
    init(volume: VolumeInfo = makeVolume(uuid: TestCard.uuid), protected: [URL] = []) throws {
        root = try makeTempFolder()
        try FileManager.default.createDirectory(at: root.appending(path: "Music"), withIntermediateDirectories: true)
        pathGuard = try PathGuard(cardRoot: root, expectedVolumeUUID: Self.uuid, profile: .q2Pod,
                                  extraProtectedFolders: protected, homeMusicFolder: fakeHomeMusic,
                                  volumeInfo: { _ in volume })
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Path guard")
struct PathGuardTests {

    @Test("Normal paths in the app's folders are approved")
    func approved() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let url = try card.pathGuard.check("Music/Adele/25/01 Hello.m4a", for: .write)
        #expect(url.path.hasSuffix("/Music/Adele/25/01 Hello.m4a"))
        _ = try card.pathGuard.check(".q2sync/manifest.json", for: .write)
        _ = try card.pathGuard.check("_explaylist_data/Mix.m3u", for: .write)
        _ = try card.pathGuard.check("Music/A/old.mp3", for: .delete)
    }

    @Test("Path traversal is refused", arguments: [
        "../outside.mp3", "Music/../../outside.mp3", "Music/./x.mp3", "/etc/passwd",
        "Music//x.mp3", "", "Music\\..\\x.mp3", "Music/A/..",
    ])
    func traversal(path: String) throws {
        let card = try TestCard(); defer { card.cleanUp() }
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check(path, for: .write) }
    }

    @Test("Absolute URLs outside the card are refused, including look-alike names")
    func outside() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let sibling = URL(filePath: card.root.path + "2/Music/x.mp3") // "/tmp/card2" vs "/tmp/card"
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check(url: sibling, for: .write) }
        #expect(throws: PathGuard.Violation.self) {
            try card.pathGuard.check(url: URL(filePath: NSTemporaryDirectory()).appending(path: "x"), for: .write)
        }
    }

    @Test("A symlinked folder on the card pointing outside is refused")
    func symlinkFolder() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let outside = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: card.root.appending(path: "Music/Evil"),
                                                   withDestinationURL: outside)
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check("Music/Evil/x.mp3", for: .write) }
    }

    @Test("A symlinked file on the card pointing outside can't be deleted or overwritten")
    func symlinkFile() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let outside = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appending(path: "precious.mp3")
        try Data("keep me".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: card.root.appending(path: "Music/link.mp3"),
                                                   withDestinationURL: target)
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check("Music/link.mp3", for: .delete) }
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check("Music/link.mp3", for: .write) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep me")
    }

    @Test("Reserved items are refused, even for user-confirmed deletes", arguments: [
        "update.tar", "Q2Pod/boot/boot-logo.jpg", ".rockbox/config.cfg", "Podcasts/ep.mp3",
        "Music/._01 Hello.m4a", "Music/.DS_Store", "Music/Live/database.ignore", "EQ/x.txt",
    ])
    func reserved(path: String) throws {
        let card = try TestCard(); defer { card.cleanUp() }
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check(path, for: .write) }
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check(path, for: .deleteConfirmedByUser) }
    }

    @Test("Normal sync operations stay inside the app's folders")
    func managedAreas() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check("Old Rips/song.mp3", for: .write) }
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check("Old Rips/song.mp3", for: .delete) }
        // …but a card-only file the user chose to delete is allowed.
        _ = try card.pathGuard.check("Old Rips/song.mp3", for: .deleteConfirmedByUser)
    }

    @Test("The card root and whole managed folders can't be deleted")
    func rootAndManagedFolders() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check(url: card.root, for: .delete) }
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.check("Music", for: .delete) }
        #expect(throws: PathGuard.Violation.self) {
            try card.pathGuard.check(url: card.root, for: .deleteConfirmedByUser)
        }
    }

    @Test("A different card with the same mount point is refused")
    func wrongUUID() throws {
        #expect(throws: PathGuard.Violation.self) {
            _ = try TestCard(volume: makeVolume(uuid: "SOMEONE-ELSES-CARD"))
        }
    }

    @Test("Internal, non-removable, startup and non-FAT disks are refused", arguments: [
        makeVolume(removable: false, ejectable: false, internalDisk: true, uuid: TestCard.uuid),
        makeVolume(removable: false, ejectable: false, uuid: TestCard.uuid),
        makeVolume(root: true, uuid: TestCard.uuid),
        makeVolume(uuid: TestCard.uuid, format: "APFS"),
    ])
    func badVolumes(volume: VolumeInfo) throws {
        #expect(throws: PathGuard.Violation.self) { _ = try TestCard(volume: volume) }
    }

    @Test("The volume is re-checked on every call (card swapped mid-sync)")
    func recheck() throws {
        let root = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: root) }
        // A thread-safe flag the fake volume reader consults.
        final class Flag: @unchecked Sendable { var swapped = false }
        let flag = Flag()
        let pathGuard = try PathGuard(cardRoot: root, expectedVolumeUUID: TestCard.uuid, profile: .q2Pod,
                                      homeMusicFolder: fakeHomeMusic,
                                      volumeInfo: { _ in makeVolume(uuid: flag.swapped ? "OTHER" : TestCard.uuid) })
        _ = try pathGuard.check("Music/x.mp3", for: .write)
        flag.swapped = true
        #expect(throws: PathGuard.Violation.self) { try pathGuard.check("Music/x.mp3", for: .write) }
    }

    @Test("Protected Mac folders are refused even if they're on the card")
    func protectedFolders() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        // Pretend the Apple Music media folder lives at <card>/Music/Media.
        let media = card.root.appending(path: "Music/Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let guarded = try PathGuard(cardRoot: card.root, expectedVolumeUUID: TestCard.uuid, profile: .q2Pod,
                                    extraProtectedFolders: [media], homeMusicFolder: fakeHomeMusic,
                                    volumeInfo: { _ in makeVolume(uuid: TestCard.uuid) })
        #expect(throws: PathGuard.Violation.self) { try guarded.check("Music/Media/song.mp3", for: .write) }
        #expect(throws: PathGuard.Violation.self) { try guarded.check("Music/Media", for: .delete) }
        _ = try guarded.check("Music/Other/song.mp3", for: .write)
    }

    @Test("A card root inside a protected folder is refused outright")
    func cardInsideProtected() throws {
        let folder = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: PathGuard.Violation.self) {
            _ = try PathGuard(cardRoot: folder, expectedVolumeUUID: TestCard.uuid, profile: .q2Pod,
                              extraProtectedFolders: [folder.deletingLastPathComponent()],
                              homeMusicFolder: fakeHomeMusic,
                              volumeInfo: { _ in makeVolume(uuid: TestCard.uuid) })
        }
    }

    @Test("The home Music folder is protected, and defaults to the real ~/Music")
    func homeMusicProtected() throws {
        // Uses a fake home Music folder that contains the card: refused.
        let fakeMusic = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: fakeMusic) }
        let inside = fakeMusic.appending(path: "Media")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        #expect(throws: PathGuard.Violation.self) {
            _ = try PathGuard(cardRoot: inside, expectedVolumeUUID: TestCard.uuid, profile: .q2Pod,
                              homeMusicFolder: fakeMusic, volumeInfo: { _ in makeVolume(uuid: TestCard.uuid) })
        }
        // The default is the real ~/Music. Only the path string is checked;
        // nothing on disk is touched.
        #expect(PathGuard.defaultHomeMusicFolder.path == PathGuard.realHomeDirectory.path + "/Music")
        #expect(!PathGuard.defaultHomeMusicFolder.path.contains("/Containers/"))
    }
}

@Suite("AppleDouble companions")
struct AppleDoubleTests {

    /// Writes a small file at a card path, creating folders.
    func write(_ card: TestCard, _ path: String, bytes: Int = 4_096) throws {
        let url = card.root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    func exists(_ card: TestCard, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: card.root.appending(path: path).path)
    }

    @Test("The ._ companion of a managed song is removed; the song stays")
    func removesCompanion() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        try write(card, "Music/A/B/01 Song.m4a")
        try write(card, "Music/A/B/._01 Song.m4a")
        #expect(card.fileSystem.removeAppleDoubleCompanion(of: "Music/A/B/01 Song.m4a") == .removed)
        #expect(card.fileSystem.removeAppleDoubleCompanion(of: "Music/A/B/01 Song.m4a") == .none)
        #expect(!exists(card, "Music/A/B/._01 Song.m4a"))
        #expect(exists(card, "Music/A/B/01 Song.m4a"))
    }

    @Test("Companions outside Q2 Sync's folders or of reserved items are left alone")
    func refusesOthers() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        try write(card, "Old Rips/x.mp3"); try write(card, "Old Rips/._x.mp3")
        try write(card, "Podcasts/ep.mp3"); try write(card, "Podcasts/._ep.mp3")
        #expect(card.fileSystem.removeAppleDoubleCompanion(of: "Old Rips/x.mp3") != .removed)
        #expect(card.fileSystem.removeAppleDoubleCompanion(of: "Podcasts/ep.mp3") != .removed)
        #expect(exists(card, "Old Rips/._x.mp3"))
        #expect(exists(card, "Podcasts/._ep.mp3"))
    }

    @Test("Oversized or symlinked companions are refused")
    func refusesSuspicious() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        try write(card, "Music/A/big.mp3")
        try write(card, "Music/A/._big.mp3", bytes: 2 << 20)
        #expect(throws: PathGuard.Violation.self) { try card.pathGuard.checkAppleDoubleCompanion(of: "Music/A/big.mp3") }

        let outside = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: outside) }
        try Data("precious".utf8).write(to: outside.appending(path: "keep"))
        try write(card, "Music/A/link.mp3")
        try FileManager.default.createSymbolicLink(at: card.root.appending(path: "Music/A/._link.mp3"),
                                                   withDestinationURL: outside.appending(path: "keep"))
        #expect(card.fileSystem.removeAppleDoubleCompanion(of: "Music/A/link.mp3") != .removed)
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "keep").path))
    }

    @Test("Timestamps use 24-hour time with no colons")
    func timestamps() {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 11, 15, 13, 19, 51)
        let date = Calendar.current.date(from: parts)!
        #expect(SyncLog.timestamp(date) == "2026-11-15 at 13.19.51")
    }
}
