//
//  DeviceStore.swift
//  Q2-Sync › Core › Device
//
//  PURPOSE
//  Remembers which cards the user confirmed as their Q2 (by volume UUID),
//  which firmware each runs, and the security-scoped bookmark that lets the
//  sandboxed app write to that card. Also remembers drives the user said
//  are NOT a Q2, so we don't keep asking.
//
//  HOW IT FITS
//  `DeviceMonitor` loads the store at launch and saves it whenever the user
//  confirms or forgets a device. Saved as a small JSON file in the app's
//  sandbox container (Application Support), never on the card or in ~/Music.
//
//  SECURITY-SCOPED BOOKMARKS (explained)
//  A sandboxed app may only touch files the user picked in an Open panel.
//  To keep that permission after the app quits, we save a "bookmark": an
//  opaque blob of data that macOS can turn back into a URL *with* the
//  permission attached. Before using it we call
//  `startAccessingSecurityScopedResource()`, and afterwards
//  `stopAccessingSecurityScopedResource()`.
//

import Foundation

/// A card the user confirmed is their Q2.
struct KnownDevice: Codable, Hashable, Identifiable, Sendable {

    /// The card's volume UUID. This is how we recognise it.
    let volumeUUID: String

    /// A friendly name, initially the volume name.
    var name: String

    /// Which firmware the Q2 runs. The user can change this later.
    var firmware: FirmwareKind

    /// Security-scoped bookmark granting write access to the card root.
    var bookmarkData: Data

    /// When the user first confirmed this card.
    let addedDate: Date

    /// `false` until a real (non-dry-run) sync has completed. The first
    /// sync for every device is a preview only (a safety rule).
    var hasCompletedFirstSync: Bool

    /// `true` once the first-sync preview (dry run) has been shown. Until
    /// then, syncing only previews. Optional for the same reason as
    /// `selection` below.
    var hasCompletedDryRun: Bool?

    /// What happens when this card connects. Optional for the same reason
    /// as `selection`; `nil` means the default, `.ask`.
    var autoSync: AutoSyncMode?

    /// The firmware version the user typed in (the Q2 shows it under About
    /// as "CFW. Version"), used for update checks. Optional.
    var installedFirmwareVersion: String?

    /// The last firmware release the user dismissed, e.g. "1.8.5".
    var dismissedFirmwareRelease: String?

    /// The auto-sync setting, with its default.
    var effectiveAutoSync: AutoSyncMode { autoSync ?? .ask }

    /// What the user chose to sync to this device.
    ///
    /// Optional so that `devices.json` files saved before this property
    /// existed still load: Swift's automatic `Codable` treats a missing
    /// optional key as `nil` instead of failing. Use `effectiveSelection`.
    var selection: SyncSelection?

    /// The selection, or an empty one if none was saved yet.
    var effectiveSelection: SyncSelection { selection ?? SyncSelection() }

    var id: String { volumeUUID }

    /// This device's firmware profile.
    var profile: DeviceProfile { firmware.profile }
}

/// Persistent list of known and ignored devices.
///
/// A `class` (not a `struct`) because the app shares one instance. It's
/// only used from the main thread via `DeviceMonitor`, so it doesn't need
/// to be `Sendable`.
final class DeviceStore {

    /// The saved file's structure.
    private struct FileFormat: Codable {
        var knownDevices: [KnownDevice] = []
        var ignoredVolumeUUIDs: Set<String> = []
    }

    /// Where the JSON is saved.
    let fileURL: URL

    /// In-memory contents.
    private var contents = FileFormat()

    /// All confirmed devices.
    var knownDevices: [KnownDevice] { contents.knownDevices }

    /// Creates a store, loading any existing file.
    ///
    /// - Parameter directory: Folder to save in. Defaults to the app's
    ///   Application Support folder (inside the sandbox container). Tests
    ///   pass a temp folder.
    init(directory: URL = DeviceStore.defaultDirectory) {
        self.fileURL = directory.appending(path: "devices.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(FileFormat.self, from: data) {
            contents = decoded
        }
        // A missing or unreadable file just means "no devices yet".
    }

    /// `~/Library/Containers/<app>/Data/Library/Application Support/Q2 Sync`
    /// when sandboxed.
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Q2 Sync", directoryHint: .isDirectory)
    }

    /// Finds a confirmed device by volume UUID.
    func device(withUUID uuid: String) -> KnownDevice? {
        contents.knownDevices.first { $0.volumeUUID == uuid }
    }

    /// `true` if the user said this volume is not a Q2.
    func isIgnored(uuid: String) -> Bool {
        contents.ignoredVolumeUUIDs.contains(uuid)
    }

    /// Adds or replaces a confirmed device and saves.
    ///
    /// - Throws: File-system errors from saving.
    func upsert(_ device: KnownDevice) throws {
        contents.knownDevices.removeAll { $0.volumeUUID == device.volumeUUID }
        contents.knownDevices.append(device)
        contents.ignoredVolumeUUIDs.remove(device.volumeUUID)
        try save()
    }

    /// Forgets a device (its bookmark and settings) and saves.
    /// Nothing on the card is touched.
    func forget(uuid: String) throws {
        contents.knownDevices.removeAll { $0.volumeUUID == uuid }
        try save()
    }

    /// Remembers that a volume is not a Q2, and saves.
    func ignore(uuid: String) throws {
        contents.ignoredVolumeUUIDs.insert(uuid)
        try save()
    }

    /// Clears the "not a Q2" list so those drives are offered again.
    func clearIgnored() throws {
        contents.ignoredVolumeUUIDs.removeAll()
        try save()
    }

    /// Writes the JSON file atomically (temp file + rename).
    ///
    /// - Side effects: Creates the directory if needed; writes one file in
    ///   the app's own container.
    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(contents).write(to: fileURL, options: .atomic)
    }
}
