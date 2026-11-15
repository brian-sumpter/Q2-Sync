//
//  MenuBarContent.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  The Q2 Sync menu in the menu bar: shows whether the Q2 is connected
//  and any sync in progress, with Sync Now, Eject, Open Q2 Sync, Settings
//  and Quit.
//
//  HOW IT FITS
//  Declared as a `MenuBarExtra` scene in `Q2SyncApp`. It can be hidden in
//  Settings. Actions go through `AutoSyncController` and `DeviceMonitor`.
//

import SwiftUI

/// The menu shown from the menu bar icon.
struct MenuBarContent: View {

    let controller: AutoSyncController

    var body: some View {
        let devices = controller.devices
        let sync = controller.sync

        if let connected = devices.connected {
            Text("“\(connected.device.name)” connected")
            if sync.phase == .running {
                Text("Syncing… \(Int(sync.progress.fractionComplete * 100))%")
            }
            Button("Sync Now") { Task { await controller.startSync(automatic: false) } }
                .disabled(sync.phase != .idle || connected.accessURL == nil)
            Button("Eject “\(connected.device.name)”") { Task { await devices.eject() } }
                .disabled(sync.phase == .running || devices.isEjecting)
        } else {
            Text("No Q2 connected")
        }

        Divider()
        Button("Open Q2 Sync") { controller.showMainWindow() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Q2 Sync") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu bar icon. It also hands SwiftUI's `openWindow` action to the
/// controller, so notifications can reopen the main window after it was
/// closed. (Only views can read `openWindow` from the environment.)
struct MenuBarLabel: View {

    let controller: AutoSyncController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: controller.sync.phase == .running ? "arrow.triangle.2.circlepath" : "ipod")
            .onAppear {
                controller.openMainWindow = { openWindow(id: Q2SyncApp.mainWindowID) }
            }
    }
}
