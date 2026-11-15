//
//  CapacityEstimate.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Works out the numbers for the Finder-style capacity bar: how much of the
//  card is Q2 Sync's music, other files, music the current selection would
//  add, and free space, plus whether the selection fits.
//
//  HOW IT FITS
//  The device page recomputes this whenever the selection changes. It's a
//  quick estimate from the manifest and the library's file sizes (no card
//  scan), so it can update instantly as you tick boxes. The full sync
//  preview later does the exact check before anything is copied.
//
//  THE MATHS
//    used          = total − free
//    music         = sizes of songs Q2 Sync has on the card (manifest)
//    other         = used − music   (firmware files, card-only music, …)
//    toAdd         = selected songs not on the card yet (library sizes)
//    deselected    = Q2 Sync songs on the card that aren't selected; they
//                    stay unless you choose to remove them in the preview
//    free after    = free − toAdd            (without removals)
//                  = free − toAdd + deselected (with removals)
//  The app always keeps `SyncSafety.reservedFreeBytes` free.
//

import Foundation

/// Capacity numbers for one card and selection.
struct CapacityEstimate: Sendable, Equatable {

    /// Whether the selection fits.
    enum Fit: Sendable, Equatable {
        /// Fits, keeping the reserve free.
        case fits
        /// Fits only if songs you deselected are removed in the preview.
        case fitsIfRemovingDeselected
        /// Doesn't fit even then; `shortBy` bytes too many.
        case doesNotFit(shortBy: Int64)
    }

    var totalBytes: Int64
    var freeBytes: Int64
    /// Q2 Sync's songs on the card that are still selected.
    var selectedMusicBytes: Int64
    /// Q2 Sync's songs on the card that are no longer selected.
    var deselectedMusicBytes: Int64
    /// Everything else on the card.
    var otherBytes: Int64
    /// Selected songs not on the card yet.
    var toAddBytes: Int64
    /// The verdict.
    var fit: Fit

    /// Free space after the sync if deselected songs are kept.
    var freeAfterBytes: Int64 { freeBytes - toAddBytes }

    /// Computes the estimate.
    ///
    /// - Parameters:
    ///   - totalBytes: Card size.
    ///   - freeBytes: Free space now.
    ///   - manifest: Songs Q2 Sync has on the card (`nil` if unknown).
    ///   - selection: The resolved selection, or `nil` if the library
    ///     hasn't been read yet (then nothing is "to add").
    ///   - reserve: Space always left free.
    /// - Returns: The estimate.
    static func compute(totalBytes: Int64, freeBytes: Int64, manifest: SyncManifest?,
                        selection: ResolvedSelection?,
                        reserve: Int64 = SyncSafety.reservedFreeBytes) -> CapacityEstimate {
        let entries = manifest?.entries ?? [:]
        let selectedIDs = Set(selection.map { ($0.tracksToSync + $0.skippedTracks).map(\.id) } ?? [])

        var selectedMusic: Int64 = 0
        var deselectedMusic: Int64 = 0
        for (id, entry) in entries {
            // Without a selection, treat everything on the card as selected.
            if selection == nil || selectedIDs.contains(id) {
                selectedMusic += Int64(entry.cardSize)
            } else {
                deselectedMusic += Int64(entry.cardSize)
            }
        }

        var toAdd: Int64 = 0
        for track in selection?.tracksToSync ?? [] {
            if let entry = entries[track.id] {
                // Re-copied if changed: count only any growth.
                if track.fileSize != entry.sourceSize {
                    toAdd += max(0, Int64(track.fileSize) - Int64(entry.cardSize))
                }
            } else {
                toAdd += Int64(track.fileSize)
            }
        }

        let used = max(0, totalBytes - freeBytes)
        let other = max(0, used - selectedMusic - deselectedMusic)

        let fit: Fit
        if freeBytes - toAdd >= reserve {
            fit = .fits
        } else if freeBytes - toAdd + deselectedMusic >= reserve {
            fit = .fitsIfRemovingDeselected
        } else {
            fit = .doesNotFit(shortBy: reserve - (freeBytes - toAdd + deselectedMusic))
        }

        return CapacityEstimate(totalBytes: totalBytes, freeBytes: freeBytes,
                                selectedMusicBytes: selectedMusic, deselectedMusicBytes: deselectedMusic,
                                otherBytes: other, toAddBytes: toAdd, fit: fit)
    }
}
