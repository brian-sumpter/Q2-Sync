//
//  Q2SyncApp.swift
//  Q2-Sync › App
//
//  PURPOSE
//  The app's entry point. `@main` tells Swift that this type starts the
//  program; SwiftUI then creates the scenes declared in `body`:
//    • the main window (a single window, like Music or Finder),
//    • the menu bar item (can be hidden in Settings),
//    • the Settings window (⌘,).
//
//  HOW IT FITS
//  It creates the long-lived models once (`LibraryModel`, `DeviceMonitor`,
//  `SyncCoordinator`, `AutoSyncController`) and hands them to the views.
//  The app keeps running when its window is closed, so it can notice your
//  Q2 connecting; quit it from the menu bar item or with ⌘Q.
//

import SwiftUI

@main
struct Q2SyncApp: App {

    /// Identifier of the main window, used to reopen it.
    static let mainWindowID = "main"

    /// UserDefaults key for "Show Q2 Sync in the menu bar".
    static let showMenuBarKey = "showMenuBarItem"

    // `@State` makes SwiftUI create each model once and keep it alive for
    // the app's lifetime (instead of recreating it on every redraw).
    @State private var library: LibraryModel
    @State private var devices: DeviceMonitor
    @State private var sync: SyncCoordinator
    @State private var autoSync: AutoSyncController

    /// Whether the menu bar item is shown (saved in UserDefaults).
    @AppStorage(showMenuBarKey) private var showMenuBarItem = true

    /// Connects an old-style AppKit "app delegate" so we can tell macOS to
    /// keep the app running after its window closes (SwiftUI quits a
    /// single-window app by default). `@NSApplicationDelegateAdaptor`
    /// creates the delegate and hands it to AppKit.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Creates the models. They depend on each other, so they're built
    /// here in order rather than as separate property initial values.
    init() {
        let library = LibraryModel()
        let devices = DeviceMonitor()
        let sync = SyncCoordinator()
        _library = State(initialValue: library)
        _devices = State(initialValue: devices)
        _sync = State(initialValue: sync)
        _autoSync = State(initialValue: AutoSyncController(library: library, devices: devices, sync: sync))
    }

    var body: some Scene {
        Window("Q2 Sync", id: Self.mainWindowID) {
            RootView(library: library, devices: devices)
                // `.environment` makes these available to any view inside,
                // which reads them with `@Environment`.
                .environment(sync)
                .environment(autoSync)
                .frame(minWidth: 900, minHeight: 560)
                .background(WindowOpenerBridge(controller: autoSync))
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarContent(controller: autoSync)
        } label: {
            MenuBarLabel(controller: autoSync)
        }

        Settings {
            AppSettingsView(devices: devices)
        }
    }
}

/// AppKit hooks SwiftUI doesn't offer directly.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Keep running (in the menu bar) after the main window is closed, so
    /// Q2 Sync still notices the Q2 connecting. Quit with ⌘Q or the menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// An invisible view that hands SwiftUI's `openWindow` action to the
/// auto-sync controller, so notifications can reopen the main window even
/// when the menu bar item is hidden.
private struct WindowOpenerBridge: View {
    let controller: AutoSyncController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            controller.openMainWindow = { openWindow(id: Q2SyncApp.mainWindowID) }
        }
    }
}
