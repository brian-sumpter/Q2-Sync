//
//  AppSettingsView.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  The app's Settings window (Q2 Sync › Settings…, or ⌘,): show the menu
//  bar item, and open Q2 Sync at login so auto-sync works without opening
//  the app yourself.
//
//  HOW IT FITS
//  Declared as the `Settings` scene in `Q2SyncApp`. Per-card settings
//  (firmware, "When This Q2 Connects") live on that card's Settings tab.
//
//  LOGIN ITEMS (explained)
//  `SMAppService.mainApp` is Apple's API for "open this app at login". It
//  shows up in System Settings › General › Login Items, where you can
//  also turn it off. macOS may ask you to approve it there.
//

import ServiceManagement
import SwiftUI

/// The Settings window.
struct AppSettingsView: View {

    /// For forgetting drives marked "Not My Q2".
    let devices: DeviceMonitor

    /// Saved in the app's preferences. `@AppStorage` reads and writes
    /// UserDefaults and redraws the view when it changes.
    @AppStorage(Q2SyncApp.showMenuBarKey) private var showMenuBarItem = true

    /// Whether Q2 Sync opens at login (read from macOS).
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    /// A problem changing the login item, if any.
    @State private var loginItemMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show Q2 Sync in the menu bar", isOn: $showMenuBarItem)
                Toggle("Open Q2 Sync at login", isOn: Binding(
                    get: { opensAtLogin },
                    set: { setOpensAtLogin($0) }))
                if let loginItemMessage {
                    Text(loginItemMessage).font(.callout).foregroundStyle(.orange)
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            } footer: {
                Text("Keep Q2 Sync running (it stays in the menu bar when its window is closed) so it notices when your Q2 connects. Choose what happens then in each Q2's Settings tab.")
            }

            Section {
                Button("Ask Again About Drives Marked “Not My Q2”") { devices.clearIgnoredDrives() }
            } footer: {
                Text("Use this if you marked your Q2's card as “Not My Q2” by mistake.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    /// Registers or unregisters the login item.
    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Approve Q2 Sync in System Settings › General › Login Items." : nil
        } catch {
            loginItemMessage = "Couldn't change this: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
