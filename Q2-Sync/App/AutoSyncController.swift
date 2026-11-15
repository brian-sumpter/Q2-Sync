//
//  AutoSyncController.swift
//  Q2-Sync › App
//
//  PURPOSE
//  Connects the pieces that make Q2 Sync work in the background:
//    • when your Q2 connects, it asks (notification) or syncs straight
//      away, depending on that card's "When This Q2 Connects" setting;
//    • it turns automatic syncs' outcomes into notifications;
//    • it handles the notification buttons (Sync Now, Eject, Open).
//
//  SAFETY
//  Automatic syncs go through exactly the same engine and checks as
//  manual ones. `SyncCoordinator` consults `AutoSyncPolicy`, which stops
//  and leaves the preview open whenever anything needs your review (first
//  sync, failed checks, removals, songs gone from your library). Auto-sync
//  never removes anything, and never ejects: the "finished" notification
//  offers an Eject button instead.
//

import AppKit
import Observation

/// Coordinates auto-sync, notifications and the menu bar.
@MainActor
@Observable
final class AutoSyncController {

    let library: LibraryModel
    let devices: DeviceMonitor
    let sync: SyncCoordinator

    /// Posts notifications and reports their buttons.
    @ObservationIgnored let notifications = NotificationManager()

    /// Optional Q2 Pod firmware update checks.
    let firmware = FirmwareModel()

    /// Opens (or brings forward) the main window. Set by a view that has
    /// SwiftUI's `openWindow` action, since only views can get it.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Creates the controller and starts watching for the Q2.
    init(library: LibraryModel, devices: DeviceMonitor, sync: SyncCoordinator) {
        self.library = library
        self.devices = devices
        self.sync = sync

        notifications.configure()
        // `[weak self]` avoids a retain cycle: these closures are stored by
        // objects this controller owns references to.
        devices.onDeviceConnected = { [weak self] connected in self?.deviceConnected(connected) }
        sync.onAutomaticEvent = { [weak self] event in self?.handle(event) }
        notifications.onAction = { [weak self] action in self?.handle(action) }
        devices.start()
    }

    // MARK: - Connecting

    /// The Q2 connected: do what its setting says.
    private func deviceConnected(_ connected: ConnectedDevice) {
        Task { await checkFirmware(for: connected.device) }
        let mode = connected.device.effectiveAutoSync
        guard mode != .off else { return }
        Task {
            await notifications.requestPermission()
            switch mode {
            case .off: break
            case .ask: notifications.postConnected(deviceName: connected.device.name)
            case .automatic: await startSync(automatic: true)
            }
        }
    }

    /// Starts a sync of the connected Q2.
    ///
    /// - Parameter automatic: `true` applies it without the preview when
    ///   `AutoSyncPolicy` allows; `false` shows the preview as usual.
    func startSync(automatic: Bool) async {
        guard let connected = devices.connected, sync.phase == .idle else { return }
        if !automatic { showMainWindow() }
        await sync.prepare(connected: connected, library: library, devices: devices, automatic: automatic)
    }

    /// Checks for Q2 Pod updates (if turned on, at most daily) and announces
    /// a new release once.
    private func checkFirmware(for device: KnownDevice) async {
        guard device.firmware == .q2Pod, firmware.isEnabled else { return }
        await firmware.checkIfDue()
        guard let latest = firmware.latest, firmware.status(for: device)?.shouldNotify == true,
              firmware.shouldAnnounce(latest) else { return }
        await notifications.requestPermission()
        notifications.postFirmware(title: "Q2 Pod \(latest.tag) Is Available",
                                   body: "See what's new in Q2 Sync › your Q2 › Settings. Q2 Sync doesn't install firmware; update on the Q2 itself.")
    }

    // MARK: - Outcomes

    private func handle(_ event: SyncCoordinator.AutomaticEvent) {
        let name = devices.connected?.device.name ?? "Your Q2"
        switch event {
        case .upToDate:
            notifications.postFinished(title: "“\(name)” Is Up to Date",
                                       body: "Nothing needed syncing.", offerEject: true)
        case .needsReview(let reasons):
            notifications.postNeedsReview(reasons: reasons)
            showMainWindow()
        case .finished(let report):
            if report.succeeded {
                var body = "Added \(report.added), updated \(report.updated)."
                let cardOnly = sync.preview?.plan.cardOnly.count ?? 0
                if cardOnly > 0 {
                    body += " \(cardOnly) files on the card aren't in your library; open Q2 Sync to review them."
                }
                notifications.postFinished(title: "Sync Complete", body: body, offerEject: true)
            } else {
                let reason = report.abortReason ?? (report.wasCancelled ? "It was cancelled."
                                                    : "\(report.errors.count) songs had problems.")
                notifications.postFinished(title: "Sync Stopped", body: reason + " The card is still connected.",
                                           offerEject: false)
            }
        case .failed(let message):
            notifications.postFinished(title: "Sync Stopped", body: message, offerEject: false)
        }
    }

    private func handle(_ action: NotificationAction) {
        switch action {
        case .syncNow:
            // From "Q2 connected — sync now?": same safety rules as auto-sync.
            Task { await startSync(automatic: true) }
        case .eject:
            Task { await devices.eject() }
        case .open:
            showMainWindow()
        }
    }

    /// Brings the app and its main window to the front: an open (or
    /// minimised) window is brought forward; a closed one is reopened.
    func showMainWindow() {
        // From the menu bar, the app may not be the active app yet.
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI names the window's identifier after the scene id
        // (e.g. "main" or "main-AppWindow-1").
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(Q2SyncApp.mainWindowID) == true
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}
