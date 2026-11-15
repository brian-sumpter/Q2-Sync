//
//  DeviceMonitor.swift
//  Q2-Sync › App
//
//  PURPOSE
//  Watches for disks being connected and disconnected, recognises the
//  user's Q2 card by its volume UUID, asks about new cards, and ejects.
//
//  HOW IT FITS
//      macOS (NSWorkspace mount/unmount notifications)
//            │
//            ▼
//      DeviceMonitor ──uses──▶ VolumeInfo / VolumeEligibility / DeviceStore (Core)
//            │
//            ▼
//      Sidebar "Devices" section, DeviceView, NewDeviceSheet
//
//  SAFETY
//  • Only volumes passing `VolumeEligibility` are ever considered.
//  • A card is "the Q2" only when its UUID matches one the user confirmed
//    AND the saved bookmark resolves to a volume with that same UUID. A
//    different drive with the same name is never mistaken for it.
//  • Write access comes only from a security-scoped bookmark the user
//    granted for that card in an Open panel.
//  • Before access is granted, we only read volume metadata (name, size,
//    UUID). We never list or open files on an unconfirmed drive.
//

import AppKit
import Observation
import OSLog

/// The user's Q2 card, connected and ready.
struct ConnectedDevice: Equatable {
    /// The saved device record.
    var device: KnownDevice
    /// Live facts about the mounted volume.
    var volume: VolumeInfo
    /// The card root URL with sandbox access (from the bookmark), or `nil`
    /// if access couldn't be restored.
    var accessURL: URL?
    /// Why `accessURL` is `nil`, for the UI.
    var accessProblem: String?
}

/// Tracks mounted volumes and the user's Q2.
@MainActor
@Observable
final class DeviceMonitor {

    // MARK: State the UI reads

    /// The confirmed Q2 card, if one is connected.
    private(set) var connected: ConnectedDevice?

    /// A newly seen eligible drive waiting for the user to say whether it's
    /// their Q2. Drives the "Is this your Q2?" sheet.
    var pendingVolume: VolumeInfo?

    /// Eligible drives the user postponed ("Later") this session. Shown in
    /// the sidebar with a "Set Up…" button.
    private(set) var postponedVolumes: [VolumeInfo] = []

    /// The last error to show in an alert, if any.
    var errorMessage: String?

    /// `true` while an eject is in progress.
    private(set) var isEjecting = false

    /// Called whenever the user's Q2 connects and is ready (used by
    /// auto-sync).
    var onDeviceConnected: ((ConnectedDevice) -> Void)?

    /// Q2 Sync's record of the connected card (for the capacity bar), or
    /// `nil` if it couldn't be read.
    private(set) var cardManifest: SyncManifest?

    // MARK: Private

    /// Saved devices and ignored drives.
    private let store: DeviceStore

    /// UUIDs postponed this session (not saved: asked again next launch).
    private var postponedUUIDs: Set<String> = []

    /// Our notification observers, kept so they stay registered.
    private var observers: [NSObjectProtocol] = []

    private static let logger = Logger(subsystem: "io.github.q2sync.Q2Sync", category: "device")

    /// Creates the monitor.
    /// - Parameter store: Where devices are remembered.
    init(store: DeviceStore = DeviceStore()) {
        self.store = store
    }

    // MARK: - Watching

    /// Starts watching for mounts and checks what's already connected.
    ///
    /// - Side effects: Registers NSWorkspace notification observers.
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            // `queue: .main` delivers on the main thread, and
            // `MainActor.assumeIsolated` tells the compiler we know that,
            // so we can call our main-actor method synchronously.
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(observer)
        }
        refresh()
    }

    /// Re-reads every mounted volume and updates `connected`,
    /// `pendingVolume` and `postponedVolumes`.
    ///
    /// Re-scanning everything on each notification is simpler and more
    /// robust than tracking individual mount events.
    func refresh() {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let eligible = urls.compactMap(VolumeInfo.read).filter(VolumeEligibility.isEligible)

        // 1. Is the connected Q2 still mounted?
        if let current = connected, !eligible.contains(where: { $0.uuid == current.device.volumeUUID }) {
            disconnect()
        }

        // 2. Connect to a known device if one is mounted.
        if connected == nil, let match = firstKnownDevice(in: eligible) {
            connect(device: match.device, volume: match.volume)
        } else if let current = connected,
                  let volume = eligible.first(where: { $0.uuid == current.device.volumeUUID }) {
            connected?.volume = volume // Update free space, name, etc.
        }

        // 3. Unknown drives: ask once, unless ignored or postponed.
        let unknown = eligible.filter { volume in
            guard let uuid = volume.uuid else { return false }
            return store.device(withUUID: uuid) == nil && !store.isIgnored(uuid: uuid)
        }
        postponedVolumes = unknown.filter { postponedUUIDs.contains($0.uuid ?? "") }
        if let pending = pendingVolume, !unknown.contains(pending) {
            pendingVolume = nil // It was unplugged while we were asking.
        }
        if pendingVolume == nil, connected == nil {
            pendingVolume = unknown.first { !postponedUUIDs.contains($0.uuid ?? "") }
        }
    }

    /// Finds the first mounted volume whose UUID belongs to a confirmed Q2.
    ///
    /// - Parameter volumes: Eligible mounted volumes.
    /// - Returns: The volume and its saved record, or `nil`.
    private func firstKnownDevice(in volumes: [VolumeInfo]) -> (volume: VolumeInfo, device: KnownDevice)? {
        for volume in volumes {
            if let uuid = volume.uuid, let device = store.device(withUUID: uuid) {
                return (volume, device)
            }
        }
        return nil
    }

    // MARK: - Connecting

    /// Restores sandbox access to a known card from its bookmark.
    ///
    /// - Parameters:
    ///   - device: The saved record.
    ///   - volume: The mounted volume with the matching UUID.
    /// - Side effects: Starts security-scoped access (balanced in
    ///   `disconnect()`); may refresh a stale bookmark in the store.
    private func connect(device: KnownDevice, volume: VolumeInfo) {
        var device = device
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: device.bookmarkData,
                              options: [.withSecurityScope],
                              bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            // Double-check the bookmark leads to the SAME card.
            guard VolumeInfo.read(at: url)?.uuid == device.volumeUUID else {
                url.stopAccessingSecurityScopedResource()
                connected = ConnectedDevice(device: device, volume: volume, accessURL: nil,
                                            accessProblem: "The saved access points to a different drive. Grant access again.")
                return
            }
            if isStale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) {
                device.bookmarkData = fresh
                try? store.upsert(device)
            }
            connected = ConnectedDevice(device: device, volume: volume, accessURL: url, accessProblem: nil)
            reloadManifest()
            Self.logger.notice("Connected to known Q2 card")
            if let connected { onDeviceConnected?(connected) }
        } catch {
            connected = ConnectedDevice(device: device, volume: volume, accessURL: nil,
                                        accessProblem: "Q2 Sync no longer has permission to use this card. Grant access again.")
        }
    }

    /// Clears the connected device and releases sandbox access.
    private func disconnect() {
        connected?.accessURL?.stopAccessingSecurityScopedResource()
        connected = nil
        cardManifest = nil
    }

    /// Re-reads the card's manifest (read-only), e.g. after a sync.
    func reloadManifest() {
        guard let current = connected, let root = current.accessURL else { cardManifest = nil; return }
        cardManifest = try? SyncManifest.load(cardRoot: root, profile: current.device.profile)
    }

    /// Updates free space and the manifest after the card's contents changed.
    func reloadCardInfo() {
        refresh()
        reloadManifest()
    }

    // MARK: - First-connection flow

    /// The user confirmed a drive is their Q2. Asks macOS for write access
    /// to it via an Open panel, then remembers it.
    ///
    /// - Parameters:
    ///   - volume: The drive the user confirmed.
    ///   - firmware: The firmware they said it runs.
    /// - Side effects: Shows an Open panel; saves the device; connects.
    func confirm(_ volume: VolumeInfo, firmware: FirmwareKind) {
        guard let uuid = volume.uuid else { return }

        guard let grantedURL = CardAccessPanel.requestAccess(to: volume) else {
            return // User cancelled; the sheet stays so they can try again.
        }
        defer { grantedURL.stopAccessingSecurityScopedResource() }

        // The user must have picked the card's root, not another folder.
        guard grantedURL.standardizedFileURL.path == volume.url.standardizedFileURL.path,
              VolumeInfo.read(at: grantedURL)?.uuid == uuid else {
            errorMessage = "Please select the card itself (“\(volume.name)”), not a folder on it or another drive."
            return
        }

        do {
            let bookmark = try grantedURL.bookmarkData(options: [.withSecurityScope])
            let device = KnownDevice(volumeUUID: uuid, name: volume.name, firmware: firmware,
                                     bookmarkData: bookmark, addedDate: .now, hasCompletedFirstSync: false)
            try store.upsert(device)
            pendingVolume = nil
            postponedUUIDs.remove(uuid)
            disconnect()
            refresh()
        } catch {
            errorMessage = "Couldn't remember this card: \(error.localizedDescription)"
        }
    }

    /// Re-grants access for the connected card (e.g. after a stale bookmark).
    func regrantAccess() {
        guard let current = connected else { return }
        disconnect()
        confirm(current.volume, firmware: current.device.firmware)
    }

    /// The user said the drive is not their Q2. Remembered permanently.
    func markNotQ2(_ volume: VolumeInfo) {
        guard let uuid = volume.uuid else { return }
        try? store.ignore(uuid: uuid)
        pendingVolume = nil
        refresh()
    }

    /// The user wants to decide later. Asked again next launch.
    func postpone(_ volume: VolumeInfo) {
        guard let uuid = volume.uuid else { return }
        postponedUUIDs.insert(uuid)
        pendingVolume = nil
        refresh()
    }

    /// Forgets every "Not My Q2" answer, so those drives are offered again.
    func clearIgnoredDrives() {
        try? store.clearIgnored()
        refresh()
    }

    /// Re-opens the setup sheet for a postponed drive.
    func setUp(_ volume: VolumeInfo) {
        postponedUUIDs.remove(volume.uuid ?? "")
        pendingVolume = volume
        refresh()
    }

    // MARK: - Managing the known device

    /// Changes which firmware the connected Q2 runs.
    func setFirmware(_ firmware: FirmwareKind) {
        guard var device = connected?.device else { return }
        device.firmware = firmware
        do {
            try store.upsert(device)
            connected?.device = device
        } catch {
            errorMessage = "Couldn't save the firmware choice: \(error.localizedDescription)"
        }
    }

    /// Saves a new sync selection for the connected Q2.
    ///
    /// Called on every checkbox click, so the choice is never lost.
    /// - Parameter selection: The updated selection.
    /// - Side effects: Writes `devices.json` in the app's container.
    func setSelection(_ selection: SyncSelection) {
        guard var device = connected?.device, device.selection != selection else { return }
        device.selection = selection
        do {
            try store.upsert(device)
            connected?.device = device
        } catch {
            errorMessage = "Couldn't save your selection: \(error.localizedDescription)"
        }
    }

    /// Saves the firmware version the user typed in (blank clears it).
    func setInstalledFirmwareVersion(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        updateConnectedDevice { $0.installedFirmwareVersion = trimmed.isEmpty ? nil : trimmed }
    }

    /// Hides a firmware release until a newer one comes out.
    func dismissFirmwareRelease(_ tag: String) {
        updateConnectedDevice { $0.dismissedFirmwareRelease = tag }
    }

    /// Changes what happens when this Q2 connects.
    func setAutoSync(_ mode: AutoSyncMode) {
        updateConnectedDevice { $0.autoSync = mode }
    }

    /// Records that this device's first-sync preview has been shown, so
    /// the next sync may be applied.
    func markDryRunCompleted() {
        updateConnectedDevice { $0.hasCompletedDryRun = true }
    }

    /// Records that a real sync finished successfully.
    func markSyncCompleted() {
        updateConnectedDevice { $0.hasCompletedFirstSync = true }
    }

    /// Edits and saves the connected device's record.
    private func updateConnectedDevice(_ change: (inout KnownDevice) -> Void) {
        guard var device = connected?.device else { return }
        change(&device)
        do {
            try store.upsert(device)
            connected?.device = device
        } catch {
            errorMessage = "Couldn't save the device's settings: \(error.localizedDescription)"
        }
    }

    /// Forgets the connected Q2 (its access and settings). Nothing on the
    /// card is changed. The drive will be offered as new again.
    func forgetConnectedDevice() {
        guard let uuid = connected?.device.volumeUUID else { return }
        disconnect()
        try? store.forget(uuid: uuid)
        refresh()
    }

    // MARK: - Ejecting

    /// Ejects the connected Q2 card.
    ///
    /// On failure the card stays mounted and the error is shown, as the
    /// app's requirements specify.
    ///
    /// - Returns: `true` if ejected.
    /// - Side effects: Releases sandbox access, then unmounts and ejects.
    @discardableResult
    func eject() async -> Bool {
        guard let current = connected else { return false }
        isEjecting = true
        defer { isEjecting = false }

        // Release our access first; an open handle can block unmounting.
        current.accessURL?.stopAccessingSecurityScopedResource()
        do {
            try await FileManager.default.unmountVolume(at: current.volume.url,
                                                        options: [.allPartitionsAndEjectDisk])
            connected = nil
            refresh()
            return true
        } catch {
            // Still mounted: restore access so the user can carry on.
            connect(device: current.device, volume: current.volume)
            errorMessage = "The card couldn't be ejected. Close any windows or apps using it and try again. (\(error.localizedDescription))"
            return false
        }
    }
}

/// Shows the Open panel that grants the sandboxed app access to the card.
enum CardAccessPanel {

    /// Asks the user to select the card's root folder.
    ///
    /// - Parameter volume: The card to pre-select.
    /// - Returns: The chosen URL with security-scoped access already
    ///   started (the caller must call `stopAccessingSecurityScopedResource`),
    ///   or `nil` if cancelled.
    @MainActor
    static func requestAccess(to volume: VolumeInfo) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Select your Q2's card “\(volume.name)” and click Grant Access. Q2 Sync will only be able to change files on this card."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = volume.url
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}
