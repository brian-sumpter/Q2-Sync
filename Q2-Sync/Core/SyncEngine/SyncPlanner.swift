//
//  SyncPlanner.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Compares what SHOULD be on the card (the resolved selection) with what
//  IS on the card (manifest + actual files) and produces a `SyncPlan`: the
//  exact list of copies, renames and removals. Planning changes nothing;
//  it's pure computation, which makes it easy to test and to preview.
//
//  HOW IT FITS
//      ResolvedSelection + SyncManifest + card listing ──▶ SyncPlanner ──▶ SyncPlan
//      SyncPlan ──▶ preview sheet ──(user confirms)──▶ SyncExecutor
//
//  DECISIONS FOR EACH SELECTED, COPYABLE SONG
//  • In the manifest, at its expected path, file present with the recorded
//    size, Mac file unchanged          → unchanged (nothing to do)
//  • Same, but the Mac file changed    → update (re-copy over it)
//  • Same, but the card file is missing or a different size → update
//  • In the manifest but its tags now give a different path:
//      card file intact and Mac file unchanged → move (rename, no copy)
//      otherwise                               → update at the new path
//  • Not in the manifest:
//      an identical-size unmanaged file already sits at its path → adopt
//      (just record it; no copy)
//      otherwise → add (copy)
//
//  REMOVALS
//  Only songs Q2 Sync manages (in the manifest) whose track is no longer
//  selected at all. A selected song that just can't be copied right now
//  (cloud-only, missing file) is KEPT on the card. Files not in the
//  manifest are never removed here (they're "card-only" files; see CardOnlyFiles.swift).
//
//  NEVER OVERWRITE OTHERS' FILES
//  A path already used by an unmanaged file (or by another managed song)
//  is never chosen; the song gets a " (2)" name instead.
//

import Foundation

/// A copy from the Mac to the card.
struct CopyOperation: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable { case add, update }
    let kind: Kind
    let track: Track
    /// Where the song goes on the card.
    let destination: CardPath
    /// An older copy of the same song at a different path, removed after
    /// the new copy succeeds (only when the song's tags changed its path).
    let obsoletePath: CardPath?
    /// Why an update is needed, for the preview and log.
    let reason: String?
    var id: String { track.id }
}

/// A rename on the card (song unchanged, but its tags moved it).
struct MoveOperation: Sendable, Hashable, Identifiable {
    let track: Track
    let from: CardPath
    let to: CardPath
    var id: String { track.id }
}

/// Removal of a managed song that's no longer selected.
struct RemoveOperation: Sendable, Hashable, Identifiable {
    let trackID: PersistentID
    let entry: SyncManifest.Entry
    var id: String { trackID }
}

/// An unmanaged card file that already matches a selected song: recorded
/// in the manifest without copying.
struct AdoptOperation: Sendable, Hashable, Identifiable {
    let track: Track
    let path: CardPath
    let size: UInt64
    var id: String { track.id }
}

/// Everything a sync would do. Built by `SyncPlanner`, applied by `SyncExecutor`.
struct SyncPlan: Sendable {
    var copies: [CopyOperation] = []
    var moves: [MoveOperation] = []
    var removals: [RemoveOperation] = []
    var adoptions: [AdoptOperation] = []
    /// Manifest entries whose card file has vanished and whose song is no
    /// longer selected: simply forgotten.
    var forgottenEntries: [PersistentID] = []
    var unchangedCount = 0
    /// Selected songs that can't be copied (cloud-only, DRM, missing).
    var skipped: [Track] = []
    /// Playlist files to write and remove.
    var playlistPlan = PlaylistPlan()
    /// Library tracks by ID (selected and skipped), used when writing
    /// playlists for song lengths and names.
    var tracksByID: [PersistentID: Track] = [:]
    /// How many managed songs were on the card before this sync.
    var managedSongsOnCard = 0
    /// Managed songs whose track is no longer in the Mac library at all.
    /// Not removed automatically: they're offered as card-only items.
    var orphanedEntries: [RemoveOperation] = []
    /// Card-only music (unmanaged files and orphaned songs), filled in by
    /// the coordinator after planning, with tags read from the files.
    var cardOnly: [CardOnlyItem] = []

    /// Bytes that will be copied.
    var bytesToCopy: UInt64 { copies.reduce(0) { $0 + $1.track.fileSize } }

    /// Bytes freed if removals are applied.
    var bytesFreedByRemovals: UInt64 { removals.reduce(0) { $0 + $1.entry.cardSize } }

    /// Bytes freed by replacing older copies (updates).
    var bytesFreedByUpdates: UInt64 = 0

    /// Fraction of the card's songs that would be removed (0…1), counting
    /// planned removals plus card-only files set to trash or delete.
    ///
    /// - Parameter cardOnlyActions: The user's card-only choices.
    func removalFraction(cardOnlyActions: [CardPath: CardOnlyAction] = [:], includeRemovals: Bool = true) -> Double {
        let cardOnlyRemoved = cardOnly.filter { cardOnlyActions[$0.path]?.removesFromCard == true }.count
        let unmanagedOnCard = cardOnly.filter { $0.origin == .unmanaged }.count
        let total = managedSongsOnCard + unmanagedOnCard
        let removed = (includeRemovals ? removals.count : 0) + cardOnlyRemoved
        return total == 0 ? 0 : Double(removed) / Double(total)
    }

    /// Fraction for planned removals only (kept for simple callers).
    var removalFraction: Double { removalFraction() }

    /// `true` if there's nothing at all to do.
    var isEmpty: Bool {
        copies.isEmpty && moves.isEmpty && removals.isEmpty && adoptions.isEmpty && forgottenEntries.isEmpty
            && playlistPlan.writes.isEmpty && playlistPlan.removals.isEmpty
    }
}

/// Builds sync plans. Pure functions only.
enum SyncPlanner {

    /// Plans a sync.
    ///
    /// - Parameters:
    ///   - selection: The resolved selection (tracks to sync, skipped, playlists).
    ///   - allSelectedIDs: IDs of every selected track, including skipped
    ///     ones, so skipped songs already on the card aren't removed.
    ///   - manifest: The card's manifest.
    ///   - cardFiles: Files currently in the card's Music folder, keyed by `caseKey`.
    ///   - playlistFolderFiles: Files in the playlist folder, keyed by `caseKey`.
    ///   - libraryIDs: Every track ID in the Mac library. Managed songs not
    ///     in it become `orphanedEntries` instead of removals. `nil` treats
    ///     every deselected song as a normal removal.
    ///   - layout: Card layout rules.
    /// - Returns: The plan.
    static func plan(selection: ResolvedSelection,
                     allSelectedIDs: Set<PersistentID>,
                     manifest: SyncManifest,
                     cardFiles: [String: CardFile],
                     playlistFolderFiles: [String: CardFile] = [:],
                     libraryIDs: Set<PersistentID>? = nil,
                     layout: CardLayout) -> SyncPlan {
        var plan = SyncPlan()
        plan.skipped = selection.skippedTracks
        plan.playlistPlan = PlaylistWriter.plan(playlists: selection.playlists, manifest: manifest,
                                                folderFiles: playlistFolderFiles, profile: layout.profile)
        for track in selection.tracksToSync + selection.skippedTracks { plan.tracksByID[track.id] = track }

        // Which manifest entries still have their file on the card?
        plan.managedSongsOnCard = manifest.entries.values.filter {
            cardFiles[CardLayout.caseKey($0.path)] != nil
        }.count

        // Paths already spoken for (case-insensitive keys). Starts with
        // EVERY file on the card, so nothing unmanaged is ever overwritten.
        // Paths owned by selected songs are released below as needed.
        var taken = Set(cardFiles.keys)
        // Manifest paths whose file is gone are also reserved for their song.
        for entry in manifest.entries.values { taken.insert(CardLayout.caseKey(entry.path)) }

        // Who owns which path, so a song may keep its own.
        var ownerOfPath: [String: PersistentID] = [:]
        for (id, entry) in manifest.entries { ownerOfPath[CardLayout.caseKey(entry.path)] = id }

        // PASS 1: songs that keep their current path (unchanged/update).
        var pending: [Track] = []
        for track in selection.tracksToSync {
            let preferred = layout.preferredPath(for: track)
            guard let entry = manifest.entries[track.id],
                  CardLayout.isSameOrVariant(entry.path, of: preferred) else {
                pending.append(track)
                continue
            }
            let onCard = cardFiles[CardLayout.caseKey(entry.path)]
            if let reason = updateReason(track: track, entry: entry, onCard: onCard) {
                plan.copies.append(CopyOperation(kind: .update, track: track, destination: entry.path,
                                                 obsoletePath: nil, reason: reason))
                plan.bytesFreedByUpdates += onCard?.size ?? 0
            } else {
                plan.unchangedCount += 1
            }
        }

        // PASS 2: new songs, and songs whose path changed.
        var adoptedKeys = Set<String>() // Each unmanaged file is adopted at most once.
        for track in pending {
            let preferred = layout.preferredPath(for: track)
            let existing = manifest.entries[track.id]

            // Adopt an identical unmanaged file at the preferred path.
            let preferredKey = CardLayout.caseKey(preferred)
            if existing == nil, ownerOfPath[preferredKey] == nil, !adoptedKeys.contains(preferredKey),
               let file = cardFiles[preferredKey], file.size == track.fileSize {
                plan.adoptions.append(AdoptOperation(track: track, path: file.path, size: file.size))
                adoptedKeys.insert(preferredKey)
                continue
            }

            let destination = firstFreePath(for: preferred, taken: taken)
            taken.insert(CardLayout.caseKey(destination))

            if let entry = existing {
                let onCard = cardFiles[CardLayout.caseKey(entry.path)]
                let intact = onCard?.size == entry.cardSize
                if intact && !sourceChanged(track: track, entry: entry) {
                    plan.moves.append(MoveOperation(track: track, from: entry.path, to: destination))
                } else {
                    plan.copies.append(CopyOperation(kind: .update, track: track, destination: destination,
                                                     obsoletePath: onCard == nil ? nil : entry.path,
                                                     reason: "Tags changed"))
                    plan.bytesFreedByUpdates += onCard?.size ?? 0
                }
            } else {
                plan.copies.append(CopyOperation(kind: .add, track: track, destination: destination,
                                                 obsoletePath: nil, reason: nil))
            }
        }

        // REMOVALS: managed songs that are no longer selected at all.
        for (id, entry) in manifest.entries where !allSelectedIDs.contains(id) {
            if cardFiles[CardLayout.caseKey(entry.path)] != nil {
                let operation = RemoveOperation(trackID: id, entry: entry)
                if let libraryIDs, !libraryIDs.contains(id) {
                    plan.orphanedEntries.append(operation) // Gone from the Mac: ask, don't remove.
                } else {
                    plan.removals.append(operation)
                }
            } else {
                plan.forgottenEntries.append(id)
            }
        }
        plan.removals.sort { SortKey.compare($0.entry.path, $1.entry.path) }
        plan.orphanedEntries.sort { SortKey.compare($0.entry.path, $1.entry.path) }
        return plan
    }

    /// Why an existing managed song needs re-copying, or `nil` if it doesn't.
    private static func updateReason(track: Track, entry: SyncManifest.Entry, onCard: CardFile?) -> String? {
        guard let onCard else { return "Missing from the card" }
        if onCard.size != entry.cardSize { return "Changed on the card" }
        if sourceChanged(track: track, entry: entry) { return "Changed in your library" }
        return nil
    }

    /// `true` if the Mac file differs from when it was copied.
    private static func sourceChanged(track: Track, entry: SyncManifest.Entry) -> Bool {
        if track.fileSize != entry.sourceSize { return true }
        guard let now = track.modifiedDate, let then = entry.sourceModified else { return false }
        // Dates go through JSON, so allow sub-second rounding.
        return abs(now.timeIntervalSince(then)) > 1
    }

    /// The preferred path if free, otherwise its first free " (n)" variant.
    private static func firstFreePath(for preferred: CardPath, taken: Set<String>) -> CardPath {
        if !taken.contains(CardLayout.caseKey(preferred)) { return preferred }
        var number = 2
        while true {
            let candidate = CardLayout.variant(of: preferred, number: number)
            if !taken.contains(CardLayout.caseKey(candidate)) { return candidate }
            number += 1
        }
    }
}
