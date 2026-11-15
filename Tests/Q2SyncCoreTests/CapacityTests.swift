//
//  CapacityTests.swift
//  Q2-Sync › Tests
//
//  PURPOSE
//  Tests for the capacity bar's numbers and the "will it fit?" verdict.
//

import Foundation
import Testing
@testable import Q2SyncCore

@Suite("Capacity estimate")
struct CapacityEstimateTests {

    let gb: Int64 = 1_000_000_000

    /// A manifest with two songs on the card: "keep" (selected) and "old" (deselected).
    var manifest: SyncManifest {
        var manifest = SyncManifest()
        manifest.entries["keep"] = makeEntry("Music/a.mp3", size: 2_000_000_000)
        manifest.entries["old"] = makeEntry("Music/b.mp3", size: 3_000_000_000)
        return manifest
    }

    func selection(adding bytes: UInt64) -> ResolvedSelection {
        resolved([makeCopyableTrack(id: "keep", title: "Keep", size: 2_000_000_000),
                  makeCopyableTrack(id: "new", title: "New", size: bytes)])
    }

    @Test("Splits used space into selected music, deselected music and other files")
    func breakdown() {
        let estimate = CapacityEstimate.compute(totalBytes: 100 * gb, freeBytes: 90 * gb,
                                                manifest: manifest, selection: selection(adding: 1_000_000_000))
        #expect(estimate.selectedMusicBytes == 2 * gb)
        #expect(estimate.deselectedMusicBytes == 3 * gb)
        #expect(estimate.otherBytes == 5 * gb)
        #expect(estimate.toAddBytes == 1 * gb)
        #expect(estimate.freeAfterBytes == 89 * gb)
        #expect(estimate.fit == .fits)
    }

    @Test("Fits only if deselected songs are removed")
    func fitsIfRemoving() {
        let estimate = CapacityEstimate.compute(totalBytes: 100 * gb, freeBytes: 2 * gb,
                                                manifest: manifest, selection: selection(adding: 4_000_000_000))
        #expect(estimate.fit == .fitsIfRemovingDeselected)
    }

    @Test("Doesn't fit at all: reports by how much")
    func doesNotFit() {
        let estimate = CapacityEstimate.compute(totalBytes: 100 * gb, freeBytes: 2 * gb, manifest: manifest,
                                                selection: selection(adding: 10_000_000_000), reserve: 0)
        #expect(estimate.fit == .doesNotFit(shortBy: 5 * gb))
    }

    @Test("Without a library read yet, everything on the card counts as selected and nothing is added")
    func noSelection() {
        let estimate = CapacityEstimate.compute(totalBytes: 100 * gb, freeBytes: 90 * gb,
                                                manifest: manifest, selection: nil)
        #expect(estimate.selectedMusicBytes == 5 * gb)
        #expect(estimate.deselectedMusicBytes == 0)
        #expect(estimate.toAddBytes == 0)
    }

    @Test("A changed song only counts its growth")
    func changedSong() {
        var manifest = SyncManifest()
        manifest.entries["s"] = makeEntry("Music/s.mp3", size: 1_000)
        let grown = resolved([makeCopyableTrack(id: "s", title: "S", size: 1_500)])
        let shrunk = resolved([makeCopyableTrack(id: "s", title: "S", size: 500)])
        #expect(CapacityEstimate.compute(totalBytes: gb, freeBytes: gb, manifest: manifest, selection: grown).toAddBytes == 500)
        #expect(CapacityEstimate.compute(totalBytes: gb, freeBytes: gb, manifest: manifest, selection: shrunk).toAddBytes == 0)
    }
}
