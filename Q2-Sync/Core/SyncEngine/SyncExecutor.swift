//
//  SyncExecutor.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Applies a confirmed `SyncPlan` to the card: removes, moves, adopts and
//  copies, reporting progress, honouring Cancel, keeping the manifest up
//  to date, and logging every change.
//
//  HOW IT FITS
//      SyncCoordinator (App) ──run──▶ SyncExecutor ──▶ CardFileSystem ──▶ PathGuard
//                                          │
//                                          └──▶ SyncLog, SyncManifest
//
//  ORDER OF WORK
//  1. Clear leftover temp files from any interrupted sync.
//  2. Removals first (to free space), to the card's trash or deleted.
//  3. Adoptions (record identical files already on the card).
//  4. Moves (renames for retagged songs).
//  5. Copies (new and changed songs).
//  The manifest is saved every 25 operations and at the end, so stopping
//  at any point leaves an accurate record.
//
//  ERRORS
//  A problem with one song (e.g. an unreadable Mac file) is recorded and the
//  sync continues. Anything that suggests a wider problem (the path guard
//  refusing, the card filling up or disappearing) stops the sync at once.
//

import Foundation

/// Live progress for the UI.
struct SyncProgress: Sendable, Equatable {
    var completedOperations = 0
    var totalOperations = 0
    var bytesCopied: UInt64 = 0
    var totalBytes: UInt64 = 0
    /// What's happening now, e.g. "Copying “Hello”".
    var currentItem = ""

    /// 0…1, weighted by bytes when there's copying to do.
    var fractionComplete: Double {
        if totalBytes > 0 { return min(1, Double(bytesCopied) / Double(totalBytes)) }
        return totalOperations == 0 ? 1 : Double(completedOperations) / Double(totalOperations)
    }
}

/// What a finished (or stopped) sync did.
struct SyncReport: Sendable, Equatable {
    var added = 0
    var updated = 0
    var moved = 0
    var removed = 0
    var trashed = 0
    var adopted = 0
    var copiedBack = 0
    var copyBackDuplicates = 0
    var cardOnlyRemoved = 0
    var cardOnlyTrashed = 0
    var playlistsWritten = 0
    var playlistsUnchanged = 0
    var playlistsRemoved = 0
    /// Songs left out of playlists because they aren't on the card.
    var playlistSongsMissing = 0
    var skipped: [Track] = []
    /// Per-song problems, e.g. "Music/A/B/01 X.mp3: file couldn't be read".
    var errors: [String] = []
    /// Set if the whole sync was stopped by a serious problem.
    var abortReason: String?
    var wasCancelled = false
    var bytesCopied: UInt64 = 0
    var duration: Duration = .zero
    var logURL: URL?

    /// `true` only if everything planned was done without any error.
    var succeeded: Bool { errors.isEmpty && abortReason == nil && !wasCancelled }
}

/// The user's choices from the preview sheet.
struct SyncOptions: Sendable, Equatable {
    /// Apply the planned removals at all.
    var applyRemovals = false
    /// Move removed songs to `.q2sync/Trash` instead of deleting them.
    var moveRemovalsToTrash = true
    /// The user confirmed a removal above the 20% threshold.
    var largeRemovalConfirmed = false
    /// What to do with each card-only file (missing = leave).
    var cardOnlyActions: [CardPath: CardOnlyAction] = [:]
}

/// Applies sync plans to the card.
struct SyncExecutor: Sendable {

    let fileSystem: CardFileSystem
    let deviceName: String
    /// Copies card-only files to the Mac. `nil` refuses copy-backs.
    var recoveryCopier: RecoveryCopier?
    /// Where logs go (tests pass a temp folder).
    var logsDirectory: URL = SyncLog.logsDirectory

    /// Save the manifest after this many operations.
    static let manifestSaveInterval = 25

    /// Applies a plan.
    ///
    /// `@concurrent` runs this on a background thread; the long copy loop
    /// never blocks the UI. Cancel by cancelling the calling `Task`.
    ///
    /// - Parameters:
    ///   - plan: The plan the user confirmed.
    ///   - manifest: The card's current manifest.
    ///   - options: The user's choices about removals.
    ///   - onProgress: Called (from a background thread) with progress,
    ///     at most ~10 times a second.
    /// - Returns: A report of what happened.
    /// - Side effects: Changes files on the card (through the PathGuard),
    ///   saves the manifest on the card, writes a log on the Mac.
    @concurrent
    func run(plan: SyncPlan, manifest: SyncManifest, options: SyncOptions,
             onProgress: @escaping @Sendable (SyncProgress) -> Void) async -> SyncReport {
        let clock = ContinuousClock()
        let started = clock.now
        let log = SyncLog(title: "Sync", deviceName: deviceName, directory: logsDirectory)
        var manifest = manifest
        var report = SyncReport(skipped: plan.skipped, logURL: log.fileURL)

        // Defence in depth: removals above the threshold need confirmation,
        // whatever the UI did. This covers planned removals AND card-only
        // files set to trash or delete.
        let fraction = plan.removalFraction(cardOnlyActions: options.cardOnlyActions,
                                            includeRemovals: options.applyRemovals)
        let removalsAllowed = fraction <= SyncSafety.largeRemovalThreshold || options.largeRemovalConfirmed
        let removals = (options.applyRemovals && removalsAllowed) ? plan.removals : []
        let cardOnlyCopies = plan.cardOnly.filter { options.cardOnlyActions[$0.path] == .copyToMac }
        let cardOnlyRemovals = removalsAllowed
            ? plan.cardOnly.filter { options.cardOnlyActions[$0.path]?.removesFromCard == true } : []
        if !removalsAllowed {
            log.write("NOTE  Removals skipped: they exceed 20% and weren't confirmed.")
        }

        let playlistPlan = plan.playlistPlan
        var progress = SyncProgress(
            totalOperations: cardOnlyCopies.count + cardOnlyRemovals.count + removals.count + plan.adoptions.count + plan.moves.count + plan.copies.count
                + playlistPlan.writes.count + playlistPlan.removals.count,
            totalBytes: plan.bytesToCopy)
        var lastReport = clock.now
        /// Sends progress, throttled so the UI isn't flooded.
        func publish(force: Bool = false) {
            if force || clock.now - lastReport > .milliseconds(100) {
                lastReport = clock.now
                onProgress(progress)
            }
        }
        /// Marks one operation done and saves the manifest periodically.
        func finishOperation() throws {
            progress.completedOperations += 1
            publish(force: true)
            if progress.completedOperations % Self.manifestSaveInterval == 0 {
                try manifest.save(to: fileSystem)
            }
        }

        fileSystem.cleanTempFolder()
        let trashBatch = SyncLog.timestamp()
        // Songs synced earlier that left the library and that the user chose
        // to leave stay recorded in the manifest, so they're offered again.

        do {
            // 1a. Copy card-only files to the Mac first, before anything
            //     could remove them.
            for item in cardOnlyCopies {
                try Task.checkCancellation()
                progress.currentItem = "Copying “\(item.displayName)” to your Mac"
                publish(force: true)
                if item.isInLibrary {
                    log.write("COPY BACK SKIPPED  \(item.path): already in your library")
                } else if let copier = recoveryCopier {
                    do {
                        switch try copier.copyBack(source: fileSystem.urlForReading(item.path), cardPath: item.path) {
                        case .copied(let url):
                            report.copiedBack += 1
                            log.write("COPY BACK  \(item.path)  →  \(url.path)")
                        case .duplicate(let url):
                            report.copyBackDuplicates += 1
                            log.write("COPY BACK SKIPPED  \(item.path): identical file already at \(url.path)")
                        }
                    } catch let error where Self.isPerSongError(error) {
                        record(error, path: item.path, in: &report, log: log)
                    }
                } else {
                    record(RecoveryError.destinationRefused("(no recovery folder)"), path: item.path, in: &report, log: log)
                }
                try finishOperation()
            }

            // 1b. Card-only files the user chose to trash or delete.
            for item in cardOnlyRemovals {
                try Task.checkCancellation()
                progress.currentItem = "Removing “\(item.displayName)”"
                publish()
                do {
                    if options.cardOnlyActions[item.path] == .moveToTrash {
                        try fileSystem.moveToTrash(item.path, batch: trashBatch, confirmedByUser: true)
                        report.cardOnlyTrashed += 1
                        log.write("TRASH (card-only)  \(item.path)")
                    } else {
                        try fileSystem.removeFile(item.path, confirmedByUser: true)
                        report.cardOnlyRemoved += 1
                        log.write("DELETE (card-only)  \(item.path)")
                    }
                    if case .removedFromLibrary(let trackID) = item.origin { manifest.entries[trackID] = nil }
                    fileSystem.removeEmptyFolders(above: item.path)
                } catch let error where Self.isPerSongError(error) {
                    record(error, path: item.path, in: &report, log: log)
                }
                try finishOperation()
            }

            // 2. Removals.
            for removal in removals {
                try Task.checkCancellation()
                progress.currentItem = "Removing “\(removal.entry.title)”"
                publish()
                do {
                    if options.moveRemovalsToTrash {
                        try fileSystem.moveToTrash(removal.entry.path, batch: trashBatch)
                        report.trashed += 1
                        log.write("TRASH  \(removal.entry.path)")
                    } else {
                        try fileSystem.removeFile(removal.entry.path)
                        report.removed += 1
                        log.write("REMOVE  \(removal.entry.path)")
                    }
                    manifest.entries[removal.trackID] = nil
                    fileSystem.removeEmptyFolders(above: removal.entry.path)
                } catch let error where Self.isPerSongError(error) {
                    record(error, path: removal.entry.path, in: &report, log: log)
                }
                try finishOperation()
            }
            for id in plan.forgottenEntries { manifest.entries[id] = nil }

            // 3. Adoptions.
            for adoption in plan.adoptions {
                manifest.entries[adoption.track.id] = Self.entry(for: adoption.track, path: adoption.path,
                                                                 cardSize: adoption.size)
                report.adopted += 1
                log.write("ADOPT  \(adoption.path)")
                try finishOperation()
            }

            // 4. Moves.
            for move in plan.moves {
                try Task.checkCancellation()
                progress.currentItem = "Renaming “\(move.track.title)”"
                publish()
                do {
                    try fileSystem.move(move.from, to: move.to)
                    manifest.entries[move.track.id]?.path = move.to
                    fileSystem.removeEmptyFolders(above: move.from)
                    report.moved += 1
                    log.write("MOVE  \(move.from)  →  \(move.to)")
                } catch let error where Self.isPerSongError(error) {
                    record(error, path: move.from, in: &report, log: log)
                }
                try finishOperation()
            }

            // 5. Copies.
            for copy in plan.copies {
                try Task.checkCancellation()
                progress.currentItem = "Copying “\(copy.track.title)”"
                publish(force: true)
                guard let source = copy.track.fileURL else { continue }
                do {
                    let size = try fileSystem.copyFromMac(source: source, to: copy.destination) { bytes in
                        progress.bytesCopied += UInt64(bytes)
                        report.bytesCopied += UInt64(bytes)
                        publish()
                    }
                    manifest.entries[copy.track.id] = Self.entry(for: copy.track, path: copy.destination, cardSize: size)
                    if let obsolete = copy.obsoletePath,
                       CardLayout.caseKey(obsolete) != CardLayout.caseKey(copy.destination) {
                        try? fileSystem.removeFile(obsolete)
                        fileSystem.removeEmptyFolders(above: obsolete)
                    }
                    if copy.kind == .add { report.added += 1 } else { report.updated += 1 }
                    log.write("\(copy.kind == .add ? "ADD" : "UPDATE")  \(copy.destination)  (\(SyncLog.size(size)))")
                } catch let error where Self.isPerSongError(error) {
                    record(error, path: copy.destination, in: &report, log: log)
                }
                try finishOperation()
            }
            // 6. Playlists, last, so they list exactly the songs now on the card.
            for removal in playlistPlan.removals {
                try Task.checkCancellation()
                do {
                    try fileSystem.removeFile(removal.path)
                    manifest.playlistFiles[removal.playlistID] = nil
                    report.playlistsRemoved += 1
                    log.write("REMOVE PLAYLIST  \(removal.path)")
                } catch let error where Self.isPerSongError(error) {
                    record(error, path: removal.path, in: &report, log: log)
                }
                try finishOperation()
            }
            for planned in playlistPlan.writes {
                try Task.checkCancellation()
                progress.currentItem = "Writing playlist “\(planned.playlist.name)”"
                publish(force: true)
                let rendered = PlaylistWriter.render(planned.playlist, entries: manifest.entries,
                                                     tracks: plan.tracksByID, profile: fileSystem.pathGuard.profile)
                report.playlistSongsMissing += rendered.missingCount
                do {
                    // Skip the write if the file already has exactly these bytes.
                    let existing = try? Data(contentsOf: fileSystem.urlForReading(planned.path))
                    if existing == rendered.data {
                        report.playlistsUnchanged += 1
                    } else {
                        try fileSystem.writeAtomically(rendered.data, to: planned.path)
                        fileSystem.removeAppleDoubleCompanion(of: planned.path)
                        report.playlistsWritten += 1
                        log.write("PLAYLIST  \(planned.path)  (\(rendered.songCount) songs"
                            + (rendered.missingCount > 0 ? ", \(rendered.missingCount) not on card)" : ")"))
                    }
                    manifest.playlistFiles[planned.playlist.id] = planned.path
                } catch let error where Self.isPerSongError(error) {
                    record(error, path: planned.path, in: &report, log: log)
                }
                try finishOperation()
            }
        } catch is CancellationError {
            report.wasCancelled = true
            log.write("CANCELLED by the user.")
        } catch {
            report.abortReason = error.localizedDescription
            log.write("STOPPED  \(error.localizedDescription)")
        }

        // Tidy up `._` companions next to every managed song (including any
        // left by earlier syncs). Only our own songs' companions are touched.
        let tidyResults = manifest.entries.values.map { fileSystem.removeAppleDoubleCompanion(of: $0.path) }
        let removedCompanions = tidyResults.filter { $0 == .removed }.count
        if removedCompanions > 0 {
            log.write("TIDY  Removed \(removedCompanions) macOS “._” companion files")
        }
        // Log the first few failures with their reason (not a sync error:
        // the songs themselves are fine).
        let failures = tidyResults.compactMap { result -> String? in
            if case .failed(let reason) = result { return reason } else { return nil }
        }
        for reason in failures.prefix(3) { log.write("NOTE  Couldn't remove a “._” file: \(reason)") }
        if failures.count > 3 { log.write("NOTE  …and \(failures.count - 3) more “._” files") }

        // Always save the manifest, whatever happened above.
        do {
            try manifest.save(to: fileSystem)
        } catch {
            report.errors.append("Couldn't save Q2 Sync's record of the card: \(error.localizedDescription)")
            log.write("ERROR  Manifest not saved: \(error.localizedDescription)")
        }
        fileSystem.cleanTempFolder()

        report.duration = clock.now - started
        log.write(String(repeating: "-", count: 72))
        log.write("Added \(report.added), updated \(report.updated), moved \(report.moved), "
            + "removed \(report.removed), trashed \(report.trashed), adopted \(report.adopted), "
            + "copied to Mac \(report.copiedBack), card-only trashed \(report.cardOnlyTrashed) / deleted \(report.cardOnlyRemoved), "
            + "playlists written \(report.playlistsWritten) / unchanged \(report.playlistsUnchanged) / removed \(report.playlistsRemoved), "
            + "skipped \(report.skipped.count), errors \(report.errors.count). "
            + "Copied \(SyncLog.size(report.bytesCopied)) in \(report.duration.formatted(.units(allowed: [.minutes, .seconds])))")
        onProgress(progress)
        return report
    }

    // MARK: - Helpers

    /// A new manifest entry for a copied or adopted track.
    static func entry(for track: Track, path: CardPath, cardSize: UInt64) -> SyncManifest.Entry {
        SyncManifest.Entry(path: path, sourceSize: track.fileSize, sourceModified: track.modifiedDate,
                           cardSize: cardSize, syncedAt: .now, title: track.title,
                           artist: track.artist, album: track.album)
    }

    /// `true` for errors that affect one song only; `false` for errors
    /// that must stop the whole sync.
    static func isPerSongError(_ error: Error) -> Bool {
        if error is CancellationError || error is PathGuard.Violation { return false }
        if let posix = error as? POSIXError, [.ENOSPC, .ENXIO, .ENODEV, .EROFS, .EIO].contains(posix.code) {
            return false
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError { return false }
        if nsError.domain == NSPOSIXErrorDomain,
           [Int(ENOSPC), Int(ENXIO), Int(ENODEV), Int(EROFS), Int(EIO)].contains(nsError.code) {
            return false
        }
        return true
    }

    /// Records a per-song error in the report and log.
    private func record(_ error: Error, path: CardPath, in report: inout SyncReport, log: SyncLog) {
        let message = "\(path): \(error.localizedDescription)"
        report.errors.append(message)
        log.write("ERROR  \(message)")
    }
}
