//
//  CardOnlyTests.swift
//  Q2-Sync › Tests
//
//  PURPOSE
//  Tests for finding card-only music, copying it back to the Mac (with its
//  own guard and duplicate detection), and applying the user's choices.
//
//  SAFETY
//  The "Mac staging folder" and "~/Music" are temp folders. Real Downloads
//  and Music folders are never used.
//

import Foundation
import Testing
@testable import Q2SyncCore

/// Writes a file on the test card, creating folders.
func putOnCard(_ card: TestCard, _ path: String, bytes: Int = 100) throws {
    let url = card.root.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((0..<bytes).map { UInt8($0 % 200) }).write(to: url)
}

@Suite("Card-only finder")
struct CardOnlyFinderTests {

    @Test("Finds unmanaged audio anywhere except reserved items, the app folder and playlists")
    func finds() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        for path in ["Music/A/B/managed.mp3", "Music/Other/manual.flac", "Old Rips/x.mp3", "notes.txt",
                     "Podcasts/ep.mp3", ".q2sync/Trash/2026/Music/y.mp3", "_explaylist_data/Mix.m3u",
                     "Music/A/B/._managed.mp3"] {
            try putOnCard(card, path)
        }
        var manifest = SyncManifest()
        manifest.entries["M"] = makeEntry("Music/A/B/managed.mp3", size: 100)
        let items = CardOnlyFinder.find(allCardFiles: CardScanner.scan(folder: "", on: card.fileSystem),
                                        manifest: manifest, orphanedEntries: [], profile: .q2Pod)
        #expect(items.map(\.path) == ["Music/Other/manual.flac", "Old Rips/x.mp3"])
        #expect(items.allSatisfy { $0.origin == .unmanaged })
    }

    @Test("Songs that left the library become card-only, not plain removals")
    func orphans() {
        var manifest = SyncManifest()
        manifest.entries["gone"] = makeEntry("Music/A/B/01 Gone.mp3")
        manifest.entries["desel"] = makeEntry("Music/A/B/02 Deselected.mp3")
        let card = [CardFile(path: "Music/A/B/01 Gone.mp3", size: 1_000),
                    CardFile(path: "Music/A/B/02 Deselected.mp3", size: 1_000)]
        let plan = SyncPlanner.plan(selection: resolved([]), allSelectedIDs: [], manifest: manifest,
                                    cardFiles: Dictionary(card.map { (CardLayout.caseKey($0.path), $0) }, uniquingKeysWith: { a, _ in a }),
                                    libraryIDs: ["desel"], layout: CardLayout(profile: .q2Pod))
        #expect(plan.removals.map(\.trackID) == ["desel"])
        #expect(plan.orphanedEntries.map(\.trackID) == ["gone"])
    }

    @Test("Library matches need title, artist, length within 2 s, and a LOCAL file")
    func libraryMatch() {
        let local = Track(id: "1", title: "Hello", artist: "Adele", albumArtist: nil, album: nil, genre: nil,
                          trackNumber: 1, discNumber: 1, discCount: 1, isCompilation: false, durationSeconds: 295,
                          fileSize: 1, fileURL: nil, fileKind: nil, modifiedDate: nil, availability: .available)
        let cloud = Track(id: "2", title: "Skyfall", artist: "Adele", albumArtist: nil, album: nil, genre: nil,
                          trackNumber: 1, discNumber: 1, discCount: 1, isCompilation: false, durationSeconds: 286,
                          fileSize: 1, fileURL: nil, fileKind: nil, modifiedDate: nil, availability: .cloudOnly)
        let snapshot = LibrarySnapshot(tracks: [local, cloud], playlists: [], mediaFolderURL: nil)
        var items = [
            CardOnlyItem(path: "a.mp3", size: 1, origin: .unmanaged, title: "hello", artist: "ADELE", durationSeconds: 296.5),
            CardOnlyItem(path: "b.mp3", size: 1, origin: .unmanaged, title: "Hello", artist: "Adele", durationSeconds: 200),
            CardOnlyItem(path: "c.mp3", size: 1, origin: .unmanaged, title: "Skyfall", artist: "Adele", durationSeconds: 286),
            CardOnlyItem(path: "d.mp3", size: 1, origin: .unmanaged),
        ]
        CardOnlyFinder.markLibraryMatches(&items, snapshot: snapshot)
        #expect(items.map(\.isInLibrary) == [true, false, false, false])
    }

    @Test("Card-only trash/delete choices count toward the 20% check")
    func fraction() {
        var plan = SyncPlan()
        plan.managedSongsOnCard = 8
        plan.cardOnly = [CardOnlyItem(path: "x.mp3", size: 1, origin: .unmanaged),
                         CardOnlyItem(path: "y.mp3", size: 1, origin: .unmanaged)]
        #expect(plan.removalFraction(cardOnlyActions: ["x.mp3": .delete]) == 0.1)
        #expect(plan.removalFraction(cardOnlyActions: ["x.mp3": .delete, "y.mp3": .moveToTrash]) == 0.2)
        #expect(plan.removalFraction(cardOnlyActions: ["x.mp3": .copyToMac]) == 0)
        let both: [CardPath: CardOnlyAction] = ["x.mp3": .delete, "y.mp3": .delete]
        func needsConfirmation(_ plan: SyncPlan) -> Bool {
            SyncSafety.assess(plan: plan, health: .healthy, isFirstSync: false, availableBytes: 10_000_000_000,
                              includeRemovals: false, cardOnlyActions: both).needsLargeRemovalConfirmation
        }
        #expect(!needsConfirmation(plan), "Exactly 20% (2 of 10) doesn't need extra confirmation")
        plan.managedSongsOnCard = 3
        #expect(needsConfirmation(plan), "2 of 5 (40%) does")
    }
}

@Suite("Recovery copier")
struct RecoveryCopierTests {

    /// A copier writing into a temp "Downloads/Q2 Recovered", protecting a temp "Music".
    func makeCopier() throws -> (RecoveryCopier, URL, URL) {
        let home = try makeTempFolder()
        let staging = home.appending(path: "Downloads/Q2 Recovered")
        let music = home.appending(path: "Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        return (RecoveryCopier(stagingFolder: staging, protectedFolders: [music]), staging, home)
    }

    @Test("Copies into the staging folder, keeps the layout, lists it, never overwrites")
    func copies() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let (copier, staging, home) = try makeCopier(); defer { try? FileManager.default.removeItem(at: home) }
        try putOnCard(card, "Music/Artist/Album/01 Song.mp3", bytes: 2_000_000)
        let source = card.root.appending(path: "Music/Artist/Album/01 Song.mp3")

        let first = try copier.copyBack(source: source, cardPath: "Music/Artist/Album/01 Song.mp3")
        let expected = staging.appending(path: "Artist/Album/01 Song.mp3")
        #expect(first == .copied(URL(filePath: PathGuard.realPath(expected.path)!)))
        #expect(try Data(contentsOf: expected) == Data(contentsOf: source))
        #expect(FileManager.default.fileExists(atPath: source.path), "The card file stays")

        // Same file again: recognised as a duplicate.
        let second = try copier.copyBack(source: source, cardPath: "Music/Artist/Album/01 Song.mp3")
        guard case .duplicate = second else { Issue.record("Expected duplicate"); return }

        // A different file with the same name gets " (2)", nothing is overwritten.
        try putOnCard(card, "Elsewhere/Artist/Album/01 Song.mp3", bytes: 50)
        try putOnCard(card, "Music/Artist/Album/01 Song.mp3", bytes: 70)
        _ = try copier.copyBack(source: source, cardPath: "Music/Artist/Album/01 Song.mp3")
        #expect(FileManager.default.fileExists(atPath: staging.appending(path: "Artist/Album/01 Song (2).mp3").path))
        #expect(try Data(contentsOf: expected).count == 2_000_000, "Original copy untouched")

        let list = try String(contentsOf: staging.appending(path: "RECOVERED.txt"), encoding: .utf8)
        #expect(list.contains("Music/Artist/Album/01 Song.mp3"))
    }

    @Test("Destinations outside the staging folder are refused", arguments: [
        "../outside.mp3", "a/../../outside.mp3", "/etc/x", "", "a//b.mp3",
    ])
    func refusesTraversal(path: String) throws {
        let (copier, _, home) = try makeCopier(); defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: RecoveryError.self) { try copier.checkDestination(path) }
    }

    @Test("A staging folder inside a protected Music folder is refused")
    func refusesMusicFolder() throws {
        let home = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: home) }
        let music = home.appending(path: "Music")
        let copier = RecoveryCopier(stagingFolder: music.appending(path: "Q2 Recovered"), protectedFolders: [music])
        #expect(throws: RecoveryError.self) { try copier.checkDestination("x.mp3") }
    }

    @Test("A symlink in the staging folder can't redirect a copy into Music")
    func refusesSymlink() throws {
        let (copier, staging, home) = try makeCopier(); defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: staging.appending(path: "Sneaky"),
                                                   withDestinationURL: home.appending(path: "Music"))
        #expect(throws: RecoveryError.self) { try copier.checkDestination("Sneaky/x.mp3") }
    }
}

@Suite("Applying card-only choices")
struct CardOnlyExecutorTests {

    @Test("Copy to Mac, trash, delete and leave each do exactly that")
    func actions() async throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let home = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: home) }
        let logs = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: logs) }
        let staging = home.appending(path: "Q2 Recovered")
        for name in ["copy", "trash", "delete", "leave"] { try putOnCard(card, "Old/\(name).mp3") }
        // Plenty of managed songs so the 20% rule isn't triggered.
        var manifest = SyncManifest()
        for i in 0..<20 {
            try putOnCard(card, "Music/A/B/\(i).mp3")
            manifest.entries["\(i)"] = makeEntry("Music/A/B/\(i).mp3", size: 100)
        }

        var plan = SyncPlan()
        plan.managedSongsOnCard = 20
        plan.cardOnly = ["copy", "trash", "delete", "leave"].map {
            CardOnlyItem(path: "Old/\($0).mp3", size: 100, origin: .unmanaged)
        }
        let options = SyncOptions(cardOnlyActions: ["Old/copy.mp3": .copyToMac, "Old/trash.mp3": .moveToTrash,
                                                    "Old/delete.mp3": .delete])
        var executor = SyncExecutor(fileSystem: card.fileSystem, deviceName: "Test", logsDirectory: logs)
        executor.recoveryCopier = RecoveryCopier(stagingFolder: staging, protectedFolders: [fakeHomeMusic])
        let report = await executor.run(plan: plan, manifest: manifest, options: options) { _ in }

        #expect(report.succeeded)
        #expect(report.copiedBack == 1 && report.cardOnlyTrashed == 1 && report.cardOnlyRemoved == 1)
        func onCard(_ path: String) -> Bool { FileManager.default.fileExists(atPath: card.root.appending(path: path).path) }
        #expect(onCard("Old/copy.mp3"), "Copy to Mac leaves the card file")
        #expect(FileManager.default.fileExists(atPath: staging.appending(path: "Old/copy.mp3").path))
        #expect(!onCard("Old/trash.mp3"))
        #expect(!onCard("Old/delete.mp3"))
        #expect(onCard("Old/leave.mp3"))
        let trash = FileManager.default.enumerator(atPath: card.root.appending(path: ".q2sync/Trash").path)?
            .compactMap { $0 as? String } ?? []
        #expect(trash.contains { $0.hasSuffix("Old/trash.mp3") })
    }

    @Test("Unconfirmed large card-only deletions are refused by the executor")
    func largeRefused() async throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let logs = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: logs) }
        try putOnCard(card, "Old/a.mp3")
        var plan = SyncPlan()
        plan.cardOnly = [CardOnlyItem(path: "Old/a.mp3", size: 100, origin: .unmanaged)]
        let executor = SyncExecutor(fileSystem: card.fileSystem, deviceName: "Test", logsDirectory: logs)
        let report = await executor.run(plan: plan, manifest: SyncManifest(),
                                        options: SyncOptions(cardOnlyActions: ["Old/a.mp3": .delete])) { _ in }
        #expect(report.cardOnlyRemoved == 0)
        #expect(FileManager.default.fileExists(atPath: card.root.appending(path: "Old/a.mp3").path))
    }

    @Test("A song already in the library (as a local file) isn't copied back")
    func inLibrarySkipped() async throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let home = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: home) }
        let logs = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: logs) }
        try putOnCard(card, "Old/a.mp3")
        var plan = SyncPlan()
        var item = CardOnlyItem(path: "Old/a.mp3", size: 100, origin: .unmanaged)
        item.isInLibrary = true
        plan.cardOnly = [item]
        var executor = SyncExecutor(fileSystem: card.fileSystem, deviceName: "Test", logsDirectory: logs)
        executor.recoveryCopier = RecoveryCopier(stagingFolder: home.appending(path: "R"), protectedFolders: [])
        let report = await executor.run(plan: plan, manifest: SyncManifest(),
                                        options: SyncOptions(cardOnlyActions: ["Old/a.mp3": .copyToMac])) { _ in }
        #expect(report.copiedBack == 0)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "R/Old/a.mp3").path))
    }
}
