//
//  SyncCoordinator.swift
//  Q2-Sync › App
//
//  PURPOSE
//  Runs one sync from start to finish for the UI, as a simple state
//  machine:
//
//      idle ──Sync──▶ planning ──▶ preview ──Apply──▶ running ──▶ finished
//                        │            │                  │
//                        └──▶ failed  └──Cancel──▶ idle  └──Cancel──▶ finished (cancelled)
//
//  HOW IT FITS
//  The Sync button calls `prepare`; the sync sheet shows the current
//  `phase`. All real work is done by the Core engine (SelectionResolver,
//  SyncPlanner, SyncSafety, SyncExecutor); this class only wires it to the
//  UI and to `DeviceMonitor` (for ejecting and saving device state).
//
//  SAFETY
//  • The library is re-read for every sync, and the "Mac looks empty"
//    check runs first; an unsafe library stops the sync before planning.
//  • The first sync for a device only previews (dry run).
//  • Nothing is written until the user clicks Sync in the preview.
//

import Foundation
import Observation

/// Everything needed to show a preview and later apply it.
struct SyncPreview {
    let plan: SyncPlan
    let manifest: SyncManifest
    let fileSystem: CardFileSystem
    let health: LibraryHealth
    let isFirstSync: Bool
    let availableBytes: Int64
    let deviceName: String
    let profile: DeviceProfile
    /// Log of the dry run, for first syncs.
    let dryRunLogURL: URL?
    /// Mac folders copy-back must never write to (~/Music, media folder).
    let protectedFolders: [URL]

    /// Safety assessment for the user's current choices.
    func assessment(for options: SyncOptions) -> SafetyAssessment {
        SyncSafety.assess(plan: plan, health: health, isFirstSync: isFirstSync,
                          availableBytes: availableBytes, includeRemovals: options.applyRemovals,
                          cardOnlyActions: options.cardOnlyActions)
    }
}

/// Drives a sync and exposes its state to the UI.
@MainActor
@Observable
final class SyncCoordinator {

    /// Where the sync is in its lifecycle.
    enum Phase: Equatable {
        case idle
        case planning(String)
        case preview
        case running
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// The plan being previewed or applied.
    private(set) var preview: SyncPreview?

    /// The user's choices in the preview sheet.
    var options = SyncOptions()

    /// Live progress while running.
    private(set) var progress = SyncProgress()

    /// The result once finished.
    private(set) var report: SyncReport?

    /// Whether the user ejected the card from the result sheet.
    private(set) var didEject = false

    /// `true` while ejecting from the result sheet.
    private(set) var isEjecting = false

    /// The running copy task, kept so Cancel can stop it.
    private var task: Task<Void, Never>?

    /// What happened in an AUTOMATIC sync, for notifications.
    enum AutomaticEvent {
        case upToDate
        case needsReview([String])
        case finished(SyncReport)
        case failed(String)
    }

    /// `true` while the current sync was started automatically (auto-sync
    /// or a notification's "Sync Now").
    private(set) var isAutomatic = false

    /// Called with automatic syncs' outcomes (set by `AutoSyncController`).
    var onAutomaticEvent: ((AutomaticEvent) -> Void)?

    /// `true` while a sheet should be shown.
    var isPresentingSheet: Bool { phase != .idle }

    // MARK: - Planning

    /// Re-reads the library, checks safety, scans the card and builds a plan.
    ///
    /// - Parameters:
    ///   - connected: The Q2 to sync.
    ///   - library: The library model (re-read here).
    ///   - devices: For saving the dry-run state.
    /// - Side effects: Reads the library and card. For a first sync, writes
    ///   a dry-run log and marks the dry run as done. Never writes to the card.
    ///   - automatic: `true` for auto-sync: the plan is applied without
    ///     showing the preview ONLY if `AutoSyncPolicy` allows it;
    ///     otherwise the preview is shown and the user is notified.
    func prepare(connected: ConnectedDevice, library: LibraryModel, devices: DeviceMonitor,
                 automatic: Bool = false) async {
        guard phase == .idle else { return }
        options = SyncOptions()
        report = nil
        didEject = false
        isAutomatic = automatic

        phase = .planning("Reading your library…")
        await library.load()
        guard let snapshot = library.snapshot, let health = library.health else {
            fail("Your Apple Music library couldn't be read, so nothing was synced.")
            return
        }
        // The "Mac looks empty" guard: stop before even looking at the card.
        if case .unsafe(let reason) = health {
            fail(reason + " Nothing on the card was changed.")
            return
        }
        guard let cardRoot = connected.accessURL else {
            fail(connected.accessProblem ?? "Q2 Sync doesn't have access to the card.")
            return
        }

        phase = .planning("Checking the card…")
        do {
            let pathGuard = try PathGuard(
                cardRoot: cardRoot,
                expectedVolumeUUID: connected.device.volumeUUID,
                profile: connected.device.profile,
                extraProtectedFolders: [snapshot.mediaFolderURL].compactMap { $0 })
            let fileSystem = CardFileSystem(pathGuard: pathGuard)
            let selection = SelectionResolver.resolve(connected.device.effectiveSelection, in: snapshot)
            let allSelectedIDs = Set((selection.tracksToSync + selection.skippedTracks).map(\.id))

            // Scanning thousands of card files happens off the main thread.
            let (manifest, plan) = try await Self.buildPlan(selection: selection, allSelectedIDs: allSelectedIDs,
                                                            snapshot: snapshot, fileSystem: fileSystem,
                                                            profile: connected.device.profile)

            let isFirstSync = connected.device.hasCompletedDryRun != true
            var dryRunLog: URL?
            if isFirstSync {
                let log = SyncLog(title: "Dry run", deviceName: connected.device.name)
                log.write("DRY RUN — nothing was changed on the card.")
                log.describe(plan, dryRun: true)
                dryRunLog = log.fileURL
                devices.markDryRunCompleted()
            }

            // Read free space fresh: the value from when the card was
            // connected may be out of date.
            let freeNow = VolumeInfo.read(at: cardRoot)?.availableCapacity
                ?? connected.volume.availableCapacity ?? 0

            preview = SyncPreview(plan: plan, manifest: manifest, fileSystem: fileSystem, health: health,
                                  isFirstSync: isFirstSync,
                                  availableBytes: freeNow,
                                  deviceName: connected.device.name, profile: connected.device.profile,
                                  dryRunLogURL: dryRunLog,
                                  protectedFolders: [PathGuard.defaultHomeMusicFolder]
                                      + [snapshot.mediaFolderURL].compactMap { $0 })
            phase = .preview
            if automatic, let preview { decideAutomatically(preview, devices: devices) }
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// For automatic syncs: apply, close as up to date, or stop and leave
    /// the preview open for review (see `AutoSyncPolicy`).
    private func decideAutomatically(_ preview: SyncPreview, devices: DeviceMonitor) {
        // Auto-sync never removes anything: removals stay off.
        options = SyncOptions()
        switch AutoSyncPolicy.decide(plan: preview.plan, assessment: preview.assessment(for: options)) {
        case .apply:
            apply(devices: devices)
        case .nothingToDo:
            close()
            onAutomaticEvent?(.upToDate)
        case .needsReview(let reasons):
            // Leave the preview open; the user decides from here.
            isAutomatic = false
            onAutomaticEvent?(.needsReview(reasons))
        }
    }

    /// Shows a failure, and reports it if the sync was automatic.
    private func fail(_ message: String) {
        phase = .failed(message)
        if isAutomatic { onAutomaticEvent?(.failed(message)) }
        isAutomatic = false
    }

    /// Loads the manifest, scans the card, plans, and finds card-only
    /// music (reading its tags), on a background thread.
    @concurrent
    private static func buildPlan(selection: ResolvedSelection, allSelectedIDs: Set<PersistentID>,
                                  snapshot: LibrarySnapshot,
                                  fileSystem: CardFileSystem, profile: DeviceProfile) async throws
        -> (SyncManifest, SyncPlan) {
        let manifest = try SyncManifest.load(from: fileSystem)
        let cardFiles = CardScanner.scan(folder: profile.musicFolderName, on: fileSystem)
        let playlistFiles = CardScanner.scan(folder: profile.playlistFolderName, on: fileSystem)
        let plan = SyncPlanner.plan(selection: selection, allSelectedIDs: allSelectedIDs, manifest: manifest,
                                    cardFiles: cardFiles, playlistFolderFiles: playlistFiles,
                                    libraryIDs: Set(snapshot.tracks.map(\.id)),
                                    layout: CardLayout(profile: profile))
        var adjusted = plan

        // Card-only music anywhere on the card (reserved items excluded).
        let wholeCard = CardScanner.scan(folder: "", on: fileSystem)
        var cardOnly = CardOnlyFinder.find(allCardFiles: wholeCard, manifest: manifest,
                                           orphanedEntries: plan.orphanedEntries, profile: profile)
        await AudioTagReader.fillTags(&cardOnly, cardRoot: fileSystem.pathGuard.cardRoot)
        CardOnlyFinder.markLibraryMatches(&cardOnly, snapshot: snapshot)
        adjusted.cardOnly = cardOnly

        PlaylistWriter.dropUnchangedWrites(in: &adjusted, manifest: manifest, profile: profile) { path in
            try? Data(contentsOf: fileSystem.urlForReading(path))
        }
        return (manifest, adjusted)
    }

    // MARK: - Applying

    /// Applies the previewed plan. The preview sheet only enables this when
    /// the safety assessment allows it.
    ///
    /// - Parameter devices: For ejecting and saving state afterwards.
    func apply(devices: DeviceMonitor) {
        guard phase == .preview, let preview, preview.assessment(for: options).canApply else { return }
        phase = .running
        progress = SyncProgress(totalOperations: 0, totalBytes: preview.plan.bytesToCopy)
        var executor = SyncExecutor(fileSystem: preview.fileSystem, deviceName: preview.deviceName)
        executor.recoveryCopier = RecoveryCopier(stagingFolder: RecoveryCopier.defaultStagingFolder,
                                                 protectedFolders: preview.protectedFolders)
        let options = options

        task = Task {
            let result = await executor.run(plan: preview.plan, manifest: preview.manifest, options: options) { update in
                // Progress arrives on a background thread; hop to the main
                // actor before touching UI state.
                Task { @MainActor [weak self] in self?.progress = update }
            }
            await finish(with: result, devices: devices)
        }
    }

    /// Records the result. On full success, saves the device state. The
    /// card is NOT ejected automatically: the result sheet asks first, so
    /// you can keep it connected to sync again.
    private func finish(with result: SyncReport, devices: DeviceMonitor) async {
        report = result
        task = nil
        if result.succeeded {
            devices.markSyncCompleted()
        }
        // The card changed: update the capacity bar's numbers.
        devices.reloadCardInfo()
        if isAutomatic { onAutomaticEvent?(.finished(result)) }
        isAutomatic = false
        phase = .finished
    }

    /// Ejects the card when the user clicks Eject on the result sheet.
    /// If ejecting fails, `DeviceMonitor` shows the error and the card
    /// stays mounted.
    func ejectAfterSync(devices: DeviceMonitor) async {
        isEjecting = true
        didEject = await devices.eject()
        isEjecting = false
    }

    /// Stops a running sync (finishes the current chunk, then stops), or
    /// closes the preview without changing anything.
    func cancel() {
        switch phase {
        case .running: task?.cancel()
        default: close()
        }
    }

    /// Closes the sheet and resets.
    func close() {
        guard phase != .running else { return }
        phase = .idle
        preview = nil
    }
}
