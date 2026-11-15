//
//  SyncEngineTests.swift
//  Q2-Sync › Tests
//
//  PURPOSE
//  Tests for the sync planner (diffing), the safety checks and the
//  executor (real copies between two temp folders: a fake "Mac" and a
//  fake "card").
//
//  SAFETY
//  Only temp folders. The fake Mac files are checked afterwards to prove
//  they were never modified.
//

import Foundation
import Testing
@testable import Q2SyncCore

/// Builds a copyable track whose file is `fileURL`.
func makeCopyableTrack(id: String, title: String, album: String = "Album", artist: String = "Artist",
                       number: Int = 1, size: UInt64 = 1_000, modified: Date? = nil,
                       fileURL: URL = URL(filePath: "/tmp/none.mp3"),
                       availability: TrackAvailability = .available) -> Track {
    Track(id: id, title: title, artist: artist, albumArtist: artist, album: album, genre: "Rock",
          trackNumber: number, discNumber: 1, discCount: 1, isCompilation: false, durationSeconds: 100,
          fileSize: size, fileURL: fileURL, fileKind: nil, modifiedDate: modified, availability: availability)
}

/// A manifest entry for tests.
func makeEntry(_ path: CardPath, size: UInt64 = 1_000, modified: Date? = nil) -> SyncManifest.Entry {
    SyncManifest.Entry(path: path, sourceSize: size, sourceModified: modified, cardSize: size,
                       syncedAt: .now, title: "T", artist: nil, album: nil)
}

/// Shorthand for a resolved selection of tracks.
func resolved(_ tracks: [Track], skipped: [Track] = []) -> ResolvedSelection {
    ResolvedSelection(tracksToSync: tracks, skippedTracks: skipped, playlists: [], missingSelectionCount: 0)
}

/// Plans with every given track counted as selected.
func plan(_ tracks: [Track], skipped: [Track] = [], manifest: SyncManifest = SyncManifest(),
          card: [CardFile] = []) -> SyncPlan {
    SyncPlanner.plan(selection: resolved(tracks, skipped: skipped),
                     allSelectedIDs: Set((tracks + skipped).map(\.id)),
                     manifest: manifest,
                     cardFiles: Dictionary(card.map { (CardLayout.caseKey($0.path), $0) }, uniquingKeysWith: { a, _ in a }),
                     layout: CardLayout(profile: .q2Pod))
}

@Suite("Sync planner")
struct SyncPlannerTests {

    let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("New songs are added at their preferred path")
    func add() {
        let result = plan([makeCopyableTrack(id: "1", title: "One")])
        #expect(result.copies.map(\.destination) == ["Music/Artist/Album/01 One.mp3"])
        #expect(result.copies.first?.kind == .add)
    }

    @Test("Unchanged songs are left alone")
    func unchanged() {
        var manifest = SyncManifest()
        manifest.entries["1"] = makeEntry("Music/Artist/Album/01 One.mp3", modified: date)
        let result = plan([makeCopyableTrack(id: "1", title: "One", modified: date)], manifest: manifest,
                          card: [CardFile(path: "Music/Artist/Album/01 One.mp3", size: 1_000)])
        #expect(result.isEmpty)
        #expect(result.unchangedCount == 1)
    }

    @Test("Changed in the library, missing from the card, or changed on the card → update")
    func updates() {
        var manifest = SyncManifest()
        manifest.entries["1"] = makeEntry("Music/Artist/Album/01 One.mp3", modified: date)
        manifest.entries["2"] = makeEntry("Music/Artist/Album/02 Two.mp3")
        manifest.entries["3"] = makeEntry("Music/Artist/Album/03 Three.mp3")
        let result = plan([
            makeCopyableTrack(id: "1", title: "One", modified: date.addingTimeInterval(60)),
            makeCopyableTrack(id: "2", title: "Two", number: 2),
            makeCopyableTrack(id: "3", title: "Three", number: 3),
        ], manifest: manifest, card: [
            CardFile(path: "Music/Artist/Album/01 One.mp3", size: 1_000),
            CardFile(path: "Music/Artist/Album/03 Three.mp3", size: 7),
        ])
        #expect(result.copies.count == 3)
        #expect(result.copies.allSatisfy { $0.kind == .update })
        #expect(Set(result.copies.compactMap(\.reason)) ==
                ["Changed in your library", "Missing from the card", "Changed on the card"])
    }

    @Test("A retagged but unchanged song is moved, not re-copied")
    func move() {
        var manifest = SyncManifest()
        manifest.entries["1"] = makeEntry("Music/Old Name/Album/01 One.mp3")
        let result = plan([makeCopyableTrack(id: "1", title: "One", artist: "New Name")], manifest: manifest,
                          card: [CardFile(path: "Music/Old Name/Album/01 One.mp3", size: 1_000)])
        #expect(result.moves.map(\.to) == ["Music/New Name/Album/01 One.mp3"])
        #expect(result.copies.isEmpty)
    }

    @Test("Deselected managed songs are planned for removal; vanished ones are just forgotten")
    func removals() {
        var manifest = SyncManifest()
        manifest.entries["gone"] = makeEntry("Music/A/B/01 Gone.mp3")
        manifest.entries["vanished"] = makeEntry("Music/A/B/02 Vanished.mp3")
        let result = plan([], manifest: manifest, card: [CardFile(path: "Music/A/B/01 Gone.mp3", size: 1_000)])
        #expect(result.removals.map(\.trackID) == ["gone"])
        #expect(result.forgottenEntries == ["vanished"])
        #expect(result.removalFraction == 1.0)
    }

    @Test("A selected song that's temporarily uncopyable stays on the card")
    func skippedKept() {
        var manifest = SyncManifest()
        manifest.entries["1"] = makeEntry("Music/A/B/01 One.mp3")
        let missing = makeCopyableTrack(id: "1", title: "One", availability: .fileMissing)
        let result = plan([], skipped: [missing], manifest: manifest,
                          card: [CardFile(path: "Music/A/B/01 One.mp3", size: 1_000)])
        #expect(result.removals.isEmpty)
        #expect(result.skipped.map(\.id) == ["1"])
    }

    @Test("Unmanaged files are never overwritten: the new song gets a numbered name")
    func noOverwrite() {
        let result = plan([makeCopyableTrack(id: "1", title: "One", size: 5_000)],
                          card: [CardFile(path: "music/artist/album/01 ONE.mp3", size: 1_234)])
        #expect(result.copies.map(\.destination) == ["Music/Artist/Album/01 One (2).mp3"])
        #expect(result.removals.isEmpty)
    }

    @Test("An identical unmanaged file is adopted instead of copied, only once")
    func adopt() {
        let result = plan([makeCopyableTrack(id: "1", title: "One"), makeCopyableTrack(id: "2", title: "One")],
                          card: [CardFile(path: "Music/Artist/Album/01 One.mp3", size: 1_000)])
        #expect(result.adoptions.map(\.track.id) == ["1"])
        #expect(result.copies.map(\.destination) == ["Music/Artist/Album/01 One (2).mp3"])
    }

    @Test("Two new songs with the same name (ignoring case) get distinct paths")
    func caseCollision() {
        let result = plan([makeCopyableTrack(id: "1", title: "Intro"), makeCopyableTrack(id: "2", title: "INTRO")])
        let keys = Set(result.copies.map { CardLayout.caseKey($0.destination) })
        #expect(keys.count == 2)
    }

    @Test("A numbered path stays stable on the next sync")
    func stableVariant() {
        var manifest = SyncManifest()
        manifest.entries["2"] = makeEntry("Music/Artist/Album/01 One (2).mp3")
        let result = plan([makeCopyableTrack(id: "2", title: "One")], manifest: manifest,
                          card: [CardFile(path: "Music/Artist/Album/01 One (2).mp3", size: 1_000)])
        #expect(result.isEmpty)
    }
}

@Suite("Safety checks")
struct SyncSafetyTests {

    func planWithRemovals(_ count: Int, of total: Int) -> SyncPlan {
        var plan = SyncPlan()
        plan.managedSongsOnCard = total
        plan.removals = (0..<count).map { RemoveOperation(trackID: "\($0)", entry: makeEntry("Music/\($0).mp3")) }
        return plan
    }

    @Test("An unhealthy library blocks the sync")
    func unhealthy() {
        let result = SyncSafety.assess(plan: SyncPlan(), health: .unsafe("No songs"), isFirstSync: false,
                                       availableBytes: 10_000_000_000, includeRemovals: false)
        #expect(!result.canApply)
        #expect(result.blockers == ["No songs"])
    }

    @Test("The first sync is a preview only")
    func firstSync() {
        let result = SyncSafety.assess(plan: SyncPlan(), health: .healthy, isFirstSync: true,
                                       availableBytes: 10_000_000_000, includeRemovals: false)
        #expect(result.isDryRunOnly)
        #expect(!result.canApply)
    }

    @Test("Music that doesn't fit blocks the sync")
    func doesNotFit() {
        var plan = SyncPlan()
        plan.copies = [CopyOperation(kind: .add, track: makeCopyableTrack(id: "1", title: "Big", size: 5_000_000_000),
                                     destination: "Music/x.mp3", obsoletePath: nil, reason: nil)]
        let result = SyncSafety.assess(plan: plan, health: .healthy, isFirstSync: false,
                                       availableBytes: 1_000_000_000, includeRemovals: false)
        #expect(!result.canApply)
        #expect(result.projectedFreeBytes < 0)
    }

    @Test("Removing more than 20% needs extra confirmation; 20% or less doesn't")
    func largeRemoval() {
        let big = SyncSafety.assess(plan: planWithRemovals(21, of: 100), health: .healthy, isFirstSync: false,
                                    availableBytes: 10_000_000_000, includeRemovals: true)
        #expect(big.needsLargeRemovalConfirmation)
        let small = SyncSafety.assess(plan: planWithRemovals(20, of: 100), health: .healthy, isFirstSync: false,
                                      availableBytes: 10_000_000_000, includeRemovals: true)
        #expect(!small.needsLargeRemovalConfirmation)
    }
}

@Suite("Sync executor")
struct SyncExecutorTests {

    /// Writes a fake song on the fake Mac.
    func makeSource(_ folder: URL, _ name: String, bytes: Int) throws -> URL {
        let url = folder.appending(path: name)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    /// Makes a track for a real temp source file.
    func track(_ id: String, _ title: String, _ url: URL, number: Int = 1) throws -> Track {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        return makeCopyableTrack(id: id, title: title, number: number, size: size.uint64Value, fileURL: url)
    }

    /// Plans against the real temp card.
    func planOnCard(_ tracks: [Track], card: TestCard) throws -> (SyncPlan, SyncManifest) {
        let manifest = try SyncManifest.load(from: card.fileSystem)
        let files = CardScanner.scan(folder: "Music", on: card.fileSystem)
        let plan = SyncPlanner.plan(selection: resolved(tracks), allSelectedIDs: Set(tracks.map(\.id)),
                                    manifest: manifest, cardFiles: files, layout: CardLayout(profile: .q2Pod))
        return (plan, manifest)
    }

    @Test("A full sync copies, verifies, records, then a repeat sync does nothing")
    func fullSync() async throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let mac = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: mac) }
        let logs = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: logs) }

        let sourceA = try makeSource(mac, "a.mp3", bytes: 3_000_000) // > one chunk
        let sourceB = try makeSource(mac, "b.m4a", bytes: 1_234)
        let beforeA = try Data(contentsOf: sourceA)
        let datesBefore = try FileManager.default.attributesOfItem(atPath: sourceA.path)[.modificationDate] as? Date
        let tracks = [try track("A", "Alpha", sourceA), try track("B", "Beta", sourceB, number: 2)]

        let (firstPlan, manifest) = try planOnCard(tracks, card: card)
        #expect(firstPlan.copies.count == 2)

        let executor = SyncExecutor(fileSystem: card.fileSystem, deviceName: "Test", logsDirectory: logs)
        let report = await executor.run(plan: firstPlan, manifest: manifest, options: SyncOptions()) { _ in }
        #expect(report.succeeded)
        #expect(report.added == 2)

        // Copies are byte-identical; the Mac file is untouched.
        let copied = card.root.appending(path: "Music/Artist/Album/01 Alpha.mp3")
        #expect(try Data(contentsOf: copied) == beforeA)
        #expect(try Data(contentsOf: sourceA) == beforeA)
        let datesAfter = try FileManager.default.attributesOfItem(atPath: sourceA.path)[.modificationDate] as? Date
        #expect(datesBefore == datesAfter)

        // No temp files are left; the manifest and log exist.
        let temp = card.root.appending(path: ".q2sync/tmp")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: temp.path))?.isEmpty ?? true)
        #expect(try SyncManifest.load(from: card.fileSystem).entries.count == 2)
        let log = try String(contentsOf: try #require(report.logURL), encoding: .utf8)
        #expect(log.contains("ADD  Music/Artist/Album/01 Alpha.mp3"))

        // Repeat sync: nothing to do.
        let (secondPlan, _) = try planOnCard(tracks, card: card)
        #expect(secondPlan.isEmpty)
        #expect(secondPlan.unchangedCount == 2)
    }

    @Test("Removals go to the card's trash, which is hidden from Q2 Pod's library")
    func removalToTrash() async throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let mac = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: mac) }
        let logs = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: logs) }
        let tracks = [try track("A", "Alpha", try makeSource(mac, "a.mp3", bytes: 100)),
                      try track("B", "Beta", try makeSource(mac, "b.mp3", bytes: 100), number: 2)]
        let executor = SyncExecutor(fileSystem: card.fileSystem, deviceName: "Test", logsDirectory: logs)

        let (plan1, manifest1) = try planOnCard(tracks, card: card)
        _ = await executor.run(plan: plan1, manifest: manifest1, options: SyncOptions()) { _ in }

        // Deselect B. Without applyRemovals, nothing is removed.
        let (plan2, manifest2) = try planOnCard([tracks[0]], card: card)
        #expect(plan2.removals.count == 1)
        let kept = await executor.run(plan: plan2, manifest: manifest2, options: SyncOptions()) { _ in }
        #expect(kept.trashed == 0 && kept.removed == 0)
        #expect(FileManager.default.fileExists(atPath: card.root.appending(path: "Music/Artist/Album/02 Beta.mp3").path))

        // With applyRemovals + trash: moved into .q2sync/Trash, with the marker.
        // (50% removal needs the large-removal confirmation.)
        let options = SyncOptions(applyRemovals: true, moveRemovalsToTrash: true, largeRemovalConfirmed: true)
        let (plan3, manifest3) = try planOnCard([tracks[0]], card: card)
        let report = await executor.run(plan: plan3, manifest: manifest3, options: options) { _ in }
        #expect(report.trashed == 1)
        #expect(!FileManager.default.fileExists(atPath: card.root.appending(path: "Music/Artist/Album/02 Beta.mp3").path))
        #expect(FileManager.default.fileExists(atPath: card.root.appending(path: ".q2sync/Trash/database.ignore").path))
        let trashed = FileManager.default.enumerator(atPath: card.root.appending(path: ".q2sync/Trash").path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix("02 Beta.mp3") }
        #expect(trashed?.count == 1)
        #expect(try SyncManifest.load(from: card.fileSystem).entries.keys.sorted() == ["A"])
    }

    @Test("Large removals without confirmation are refused by the executor itself")
    func executorRefusesUnconfirmedLargeRemoval() async throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let logs = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: logs) }
        try Data("x".utf8).write(to: card.root.appending(path: "Music/keep.mp3"))
        var manifest = SyncManifest()
        manifest.entries["K"] = makeEntry("Music/keep.mp3", size: 1)
        let plan = SyncPlanner.plan(selection: resolved([]), allSelectedIDs: [], manifest: manifest,
                                    cardFiles: CardScanner.scan(folder: "Music", on: card.fileSystem),
                                    layout: CardLayout(profile: .q2Pod))
        let executor = SyncExecutor(fileSystem: card.fileSystem, deviceName: "Test", logsDirectory: logs)
        let report = await executor.run(plan: plan, manifest: manifest,
                                        options: SyncOptions(applyRemovals: true, moveRemovalsToTrash: false)) { _ in }
        #expect(report.removed == 0)
        #expect(FileManager.default.fileExists(atPath: card.root.appending(path: "Music/keep.mp3").path))
    }

    @Test("Cancelling stops cleanly: no temp files, accurate manifest")
    func cancel() async throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let mac = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: mac) }
        let logs = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: logs) }
        let tracks = try (1...5).map { try track("\($0)", "Song \($0)", try makeSource(mac, "\($0).mp3", bytes: 500), number: $0) }
        let (plan, manifest) = try planOnCard(tracks, card: card)
        let executor = SyncExecutor(fileSystem: card.fileSystem, deviceName: "Test", logsDirectory: logs)

        let task = Task { await executor.run(plan: plan, manifest: manifest, options: SyncOptions()) { _ in } }
        task.cancel()
        let report = await task.value
        #expect(report.wasCancelled)
        let temp = card.root.appending(path: ".q2sync/tmp")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: temp.path))?.isEmpty ?? true)
        // Whatever was copied before cancelling is recorded, nothing more.
        let saved = try SyncManifest.load(from: card.fileSystem)
        let onCard = CardScanner.scan(folder: "Music", on: card.fileSystem)
        #expect(saved.entries.count == onCard.count)
    }

    @Test("An unreadable Mac file is reported; the rest still sync")
    func perSongError() async throws {
        let card = try TestCard(); defer { card.cleanUp() }
        let mac = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: mac) }
        let logs = try makeTempFolder(); defer { try? FileManager.default.removeItem(at: logs) }
        let good = try track("G", "Good", try makeSource(mac, "g.mp3", bytes: 10))
        let missing = makeCopyableTrack(id: "M", title: "Missing", number: 2, size: 10,
                                        fileURL: mac.appending(path: "not-there.mp3"))
        let (plan, manifest) = try planOnCard([good, missing], card: card)
        let executor = SyncExecutor(fileSystem: card.fileSystem, deviceName: "Test", logsDirectory: logs)
        let report = await executor.run(plan: plan, manifest: manifest, options: SyncOptions()) { _ in }
        #expect(report.added == 1)
        #expect(report.errors.count == 1)
        #expect(!report.succeeded)
    }

    @Test("A damaged manifest stops planning instead of guessing")
    func damagedManifest() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        try FileManager.default.createDirectory(at: card.root.appending(path: ".q2sync"), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: card.root.appending(path: ".q2sync/manifest.json"))
        #expect(throws: ManifestError.self) { try SyncManifest.load(from: card.fileSystem) }
    }

    @Test("The card scanner skips reserved items")
    func scannerSkipsReserved() throws {
        let card = try TestCard(); defer { card.cleanUp() }
        for path in ["Music/a.mp3", "Music/._a.mp3", ".rockbox/x.mp3", "Podcasts/p.mp3", "Old/b.mp3"] {
            let url = card.root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let found = Set(CardScanner.scan(folder: "", on: card.fileSystem).values.map(\.path))
        #expect(found == ["Music/a.mp3", "Old/b.mp3"])
    }
}
