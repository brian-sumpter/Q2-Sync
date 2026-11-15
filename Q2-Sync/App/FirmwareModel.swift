//
//  FirmwareModel.swift
//  Q2-Sync › App
//
//  PURPOSE
//  Holds the optional Q2 Pod update check for the UI: whether checking is
//  on, the latest release found, when it last checked, and any error.
//
//  HOW IT FITS
//  Owned by `AutoSyncController`, which checks (at most once a day) when a
//  Q2 Pod device connects, and posts a notification for a new release.
//  The device's Settings tab shows the details and a "Check Now" button.
//  The actual request and comparison live in Core (`FirmwareUpdateChecker`).
//
//  It never downloads or installs firmware.
//

import Foundation
import Observation

/// UI state for firmware update checks.
@MainActor
@Observable
final class FirmwareModel {

    /// UserDefaults keys.
    static let enabledKey = "checkFirmwareUpdates"
    private static let latestKey = "latestFirmwareRelease"
    private static let lastCheckedKey = "lastFirmwareCheck"
    private static let notifiedKey = "notifiedFirmwareRelease"

    /// How often automatic checks may run.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// The latest release found (kept between launches).
    private(set) var latest: FirmwareRelease?

    /// When the last successful check happened.
    private(set) var lastChecked: Date?

    /// `true` while a check is running.
    private(set) var isChecking = false

    /// The last check's error, if it failed.
    private(set) var errorMessage: String?

    private let defaults = UserDefaults.standard

    /// Whether checking is turned on (off until the user turns it on).
    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    init() {
        if let data = defaults.data(forKey: Self.latestKey) {
            latest = try? JSONDecoder().decode(FirmwareRelease.self, from: data)
        }
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    /// Checks if checking is on and the last check was over a day ago.
    func checkIfDue() async {
        guard isEnabled else { return }
        if let lastChecked, Date.now.timeIntervalSince(lastChecked) < Self.checkInterval { return }
        await checkNow()
    }

    /// Checks GitHub right away.
    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await FirmwareUpdateChecker.fetchLatest()
            latest = release
            lastChecked = .now
            errorMessage = nil
            defaults.set(try? JSONEncoder().encode(release), forKey: Self.latestKey)
            defaults.set(lastChecked, forKey: Self.lastCheckedKey)
        } catch {
            errorMessage = "Couldn't check for updates: \(error.localizedDescription)"
        }
    }

    /// The status for a device, or `nil` if nothing has been checked yet.
    func status(for device: KnownDevice) -> FirmwareUpdateStatus? {
        guard device.firmware == .q2Pod, let latest else { return nil }
        return FirmwareUpdateChecker.status(latest: latest, installed: device.installedFirmwareVersion,
                                            dismissedTag: device.dismissedFirmwareRelease)
    }

    /// `true` the first time a given release is worth a notification, so
    /// each release is announced only once.
    func shouldAnnounce(_ release: FirmwareRelease) -> Bool {
        guard defaults.string(forKey: Self.notifiedKey) != release.tag else { return false }
        defaults.set(release.tag, forKey: Self.notifiedKey)
        return true
    }
}
