//
//  DeviceView.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  The page shown when the Q2 is selected in the sidebar, laid out like
//  Finder's iPod page: a header (icon, name, firmware, capacity, Eject)
//  and two tabs, "Music" (what to sync) and "Settings" (firmware and card).
//
//  HOW IT FITS
//  Shown by `RootView`. Actions go through `DeviceMonitor`; library data
//  comes from `LibraryModel`.
//

import AppKit
import SwiftUI

/// The two tabs on the device page.
enum DeviceTab: String, CaseIterable, Identifiable {
    case music = "Music"
    case settings = "Settings"
    var id: String { rawValue }
}

/// Header plus tabs for the connected Q2.
struct DeviceView: View {

    let connected: ConnectedDevice
    let devices: DeviceMonitor
    let library: LibraryModel

    /// Which tab is showing. Starts on Music, like Finder.
    @State private var tab: DeviceTab = .music

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeaderView(connected: connected, devices: devices, showSettings: { tab = .settings })
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Picker("Tab", selection: $tab) {
                ForEach(DeviceTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 10)

            Divider()

            switch tab {
            case .music:
                DeviceMusicView(connected: connected, devices: devices, library: library)
            case .settings:
                DeviceSettingsView(connected: connected, devices: devices)
            }
        }
        // Fill the whole detail area, pinned to the top, so the header
        // never floats to the middle when the content below is short.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(connected.device.name)
    }
}

/// Big icon, name, firmware and capacity, like Finder's device header.
struct DeviceHeaderView: View {

    let connected: ConnectedDevice
    let devices: DeviceMonitor
    /// Switches to the Settings tab (for the firmware update link).
    var showSettings: () -> Void = {}

    @Environment(AutoSyncController.self) private var autoSync

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "ipod")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(connected.device.name).font(.title2.bold())
                Text("Shanling Q2 · \(connected.device.firmware.displayName)")
                    .foregroundStyle(.secondary)
                Text(capacityText).font(.callout).foregroundStyle(.secondary)
                if let latest = autoSync.firmware.latest,
                   autoSync.firmware.status(for: connected.device)?.shouldNotify == true {
                    Button("Q2 Pod \(latest.tag) is available", systemImage: "arrow.down.circle") { showSettings() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            Spacer()
            Button {
                Task { await devices.eject() }
            } label: {
                Label("Eject", systemImage: "eject")
            }
            .disabled(devices.isEjecting)
        }
    }

    /// e.g. "256 GB · 255.1 GB available".
    private var capacityText: String {
        let style = ByteCountFormatStyle(style: .file)
        let total = connected.volume.totalCapacity.map { $0.formatted(style) } ?? "Unknown size"
        let free = connected.volume.availableCapacity.map { "\($0.formatted(style)) available" } ?? ""
        return [total, free].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The Settings tab: firmware, after-sync steps and card details.
struct DeviceSettingsView: View {

    let connected: ConnectedDevice
    let devices: DeviceMonitor

    /// Controls the "Forget this Q2?" confirmation.
    @State private var confirmingForget = false

    /// For asking notification permission when auto-sync is turned on.
    @Environment(AutoSyncController.self) private var autoSync

    var body: some View {
        Form {
            if let problem = connected.accessProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Grant Access…") { devices.regrantAccess() }
                }
            }

            Section("Firmware") {
                // A Binding that reads the current firmware and writes the
                // user's choice back through the monitor (which saves it).
                Picker("Firmware", selection: Binding(
                    get: { connected.device.firmware },
                    set: { devices.setFirmware($0) })) {
                    ForEach(FirmwareKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Text(connected.device.profile.versionLocationHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            FirmwareUpdateSection(connected: connected, devices: devices, firmware: autoSync.firmware)

            Section {
                Picker("When this Q2 connects", selection: Binding(
                    get: { connected.device.effectiveAutoSync },
                    set: { mode in
                        devices.setAutoSync(mode)
                        // Notifications need permission; ask when they're first needed.
                        if mode != .off { Task { await autoSync.notifications.requestPermission() } }
                    })) {
                    ForEach(AutoSyncMode.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Auto-Sync")
            } footer: {
                Text("Automatic syncs follow every safety rule. They never remove songs and never eject; if anything needs your review (the first sync, removals, songs gone from your library, a failed check), they stop, open the preview here, and notify you. Q2 Sync must be running, so turn on “Open at login” in Settings.")
            }

            Section("After Each Sync") {
                ForEach(Array(connected.device.profile.libraryUpdateSteps.enumerated()), id: \.offset) { index, step in
                    Label(step, systemImage: "\(index + 1).circle")
                }
            }

            Section {
                LabeledContent("Format", value: connected.volume.formatDescription ?? "Unknown")
                LabeledContent("Card ID", value: connected.device.volumeUUID)
                    .textSelection(.enabled)
                LabeledContent("Remembered Since",
                               value: connected.device.addedDate.formatted(date: .abbreviated, time: .omitted))
                Button("Show Sync Logs") {
                    let folder = SyncLog.logsDirectory
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                Button("Forget This Q2…", role: .destructive) { confirmingForget = true }
            } header: {
                Text("Card")
            } footer: {
                Text("Forgetting removes Q2 Sync's access to this card and its settings. Nothing on the card is changed.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget “\(connected.device.name)”?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { devices.forgetConnectedDevice() }
        } message: {
            Text("Q2 Sync will ask again the next time this card connects. Nothing on the card is changed.")
        }
    }
}
