//
//  DeviceTests.swift
//  Q2-Sync › Tests
//
//  PURPOSE
//  Unit tests for device profiles, the reserved-items list, volume
//  eligibility (which disks may ever be a Q2) and the device store.
//
//  SAFETY
//  Uses only in-memory values and temporary folders. No real volumes are
//  touched; `VolumeInfo` values are built by hand.
//

import Foundation
import Testing
@testable import Q2SyncCore

@Suite("Reserved items")
struct ReservedItemTests {

    /// Every profile must protect the same core items, so test them all.
    static let profiles: [DeviceProfile] = [.q2Pod, .stock]

    @Test("Firmware and app items from the docs are reserved", arguments: profiles)
    func documentedItems(profile: DeviceProfile) {
        let rules = profile.reservedItems
        let reserved = [
            "update.tar", "update.tar.part", "Q2Pod", "Q2Pod/boot/boot-logo.jpg",
            ".rockbox", ".rockbox/config.cfg", ".sldp", ".coverflow/pl_1_abc.jpg",
            "EQ", "EQ/preset.txt", "Podcasts/Show/ep1.mp3", "Audiobooks/Book.m4b",
            "Photos", "Books/a.epub", "Videos/clip.mp4", "Radio/favourites.m3u",
            "lockscreenimage/1.jpg", ".q2/apps/x.tag", ".spotify/cache/credentials.json",
            ".tidal/1.flac", ".ratings.tsv", ".scrobbler.log", "battery-log.txt",
            "q2-librespot-1.0.zip", "Music/q2-librespot.bin",
            // macOS metadata, at any depth.
            "._Song.mp3", "Music/A/._01 Song.mp3", ".DS_Store", "Music/.DS_Store",
            ".Spotlight-V100", ".fseventsd", ".Trashes",
            // Q2 Pod folder markers, at any depth.
            "Music/Live/database.ignore", "Music/Live/.database.unignore",
            // Windows leftovers.
            "System Volume Information", "$RECYCLE.BIN/x",
        ]
        for path in reserved {
            #expect(rules.isReserved(relativePath: path), "\(path) should be reserved")
        }
    }

    @Test("Matching ignores case, as FAT/exFAT do", arguments: profiles)
    func caseInsensitive(profile: DeviceProfile) {
        let rules = profile.reservedItems
        #expect(rules.isReserved(relativePath: "PODCASTS/x.mp3"))
        #expect(rules.isReserved(relativePath: "Update.TAR"))
        #expect(rules.isReserved(relativePath: "Music/DATABASE.IGNORE"))
    }

    @Test("Ordinary music and the app's own state folder are not reserved", arguments: profiles)
    func notReserved(profile: DeviceProfile) {
        let rules = profile.reservedItems
        #expect(!rules.isReserved(relativePath: "Music/Adele/25/01 Hello.m4a"))
        #expect(!rules.isReserved(relativePath: "Old Rips/song.mp3"))
        #expect(!rules.isReserved(relativePath: ".q2sync/manifest.json"))
        #expect(!rules.isReserved(relativePath: "_explaylist_data/Road Trip.m3u"))
        #expect(!rules.isReserved(components: []))
    }

    @Test("Root-only names are only reserved at the root", arguments: profiles)
    func rootOnly(profile: DeviceProfile) {
        // An album called "Photos" by some artist is ordinary music.
        #expect(!profile.reservedItems.isReserved(relativePath: "Music/Artist/Photos/01.mp3"))
    }

    @Test("The app's state folder name is only allowed at the root", arguments: profiles)
    func ownFolderOnlyAtRoot(profile: DeviceProfile) {
        #expect(profile.reservedItems.isReserved(relativePath: "Music/.q2sync/x"))
    }

    @Test("Profiles keep firmware details", arguments: profiles)
    func profileBasics(profile: DeviceProfile) {
        #expect(profile.musicFolderName == "Music")
        #expect(profile.playlistFolderName == "_explaylist_data")
        #expect(profile.maximumPlaylists == 100)
        #expect(profile.maximumPlaylistNameBytes == 63)
        #expect(!profile.libraryUpdateSteps.isEmpty)
        #expect(profile.firmware.profile == profile)
    }
}

/// Builds a fake volume description with safe defaults (a removable exFAT card).
func makeVolume(
    removable: Bool = true, ejectable: Bool = true, internalDisk: Bool = false,
    root: Bool = false, uuid: String? = "1234-ABCD", format: String? = "ExFAT"
) -> VolumeInfo {
    VolumeInfo(url: URL(filePath: "/Volumes/TEST"), uuid: uuid, name: "TEST",
               isRemovable: removable, isEjectable: ejectable, isInternal: internalDisk,
               isRootFileSystem: root, formatDescription: format,
               totalCapacity: 256_000_000_000, availableCapacity: 255_000_000_000)
}

@Suite("Volume eligibility")
struct VolumeEligibilityTests {

    @Test("An external exFAT card is eligible")
    func externalCard() {
        #expect(VolumeEligibility.isEligible(makeVolume()))
        #expect(VolumeEligibility.isEligible(makeVolume(format: "MS-DOS (FAT32)")))
    }

    @Test("A card in the Mac's built-in SD slot is eligible")
    func builtInSlot() {
        #expect(VolumeEligibility.isEligible(makeVolume(internalDisk: true)))
    }

    @Test("The startup disk is never eligible")
    func startupDisk() {
        #expect(VolumeEligibility.problem(with: makeVolume(root: true)) == .startupDisk)
    }

    @Test("Internal fixed disks are refused")
    func internalFixed() {
        let volume = makeVolume(removable: false, ejectable: false, internalDisk: true, format: "APFS")
        #expect(VolumeEligibility.problem(with: volume) == .internalFixedDisk)
    }

    @Test("Non-removable external disks are refused")
    func notRemovable() {
        #expect(VolumeEligibility.problem(with: makeVolume(removable: false, ejectable: false)) == .notRemovable)
    }

    @Test("Volumes without a UUID are refused")
    func noUUID() {
        #expect(VolumeEligibility.problem(with: makeVolume(uuid: nil)) == .noUUID)
    }

    @Test("Free space uses the larger known figure (exFAT reports 0 for 'important usage')")
    func freeSpace() {
        #expect(VolumeInfo.bestAvailableCapacity(importantUsage: 0, plain: 255_000_000_000) == 255_000_000_000)
        #expect(VolumeInfo.bestAvailableCapacity(importantUsage: 9_000, plain: 5_000) == 9_000)
        #expect(VolumeInfo.bestAvailableCapacity(importantUsage: nil, plain: 42) == 42)
        #expect(VolumeInfo.bestAvailableCapacity(importantUsage: nil, plain: nil) == nil)
    }

    @Test("Non-FAT formats are refused (e.g. an APFS USB drive)")
    func wrongFormat() {
        #expect(VolumeEligibility.problem(with: makeVolume(format: "APFS")) == .unsupportedFormat("APFS"))
        #expect(!VolumeEligibility.isEligible(makeVolume(format: nil)))
    }
}

@Suite("Device store")
struct DeviceStoreTests {

    @Test("Devices persist across store instances, and forgetting works")
    func persistence() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let device = KnownDevice(volumeUUID: "UUID-1", name: "Q2", firmware: .q2Pod,
                                 bookmarkData: Data([1, 2, 3]), addedDate: .now,
                                 hasCompletedFirstSync: false)
        try DeviceStore(directory: folder).upsert(device)

        let reloaded = DeviceStore(directory: folder)
        #expect(reloaded.device(withUUID: "UUID-1")?.firmware == .q2Pod)
        #expect(reloaded.device(withUUID: "OTHER") == nil, "A different drive must never match")

        try reloaded.forget(uuid: "UUID-1")
        #expect(DeviceStore(directory: folder).knownDevices.isEmpty)
    }

    @Test("Ignored drives are remembered; confirming one un-ignores it")
    func ignoring() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DeviceStore(directory: folder)
        try store.ignore(uuid: "BACKUP-DRIVE")
        #expect(DeviceStore(directory: folder).isIgnored(uuid: "BACKUP-DRIVE"))

        try store.upsert(KnownDevice(volumeUUID: "BACKUP-DRIVE", name: "X", firmware: .stock,
                                     bookmarkData: Data(), addedDate: .now, hasCompletedFirstSync: false))
        #expect(!store.isIgnored(uuid: "BACKUP-DRIVE"))
    }

    @Test("A corrupt file is treated as empty, not a crash")
    func corruptFile() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{oops".utf8).write(to: folder.appending(path: "devices.json"))
        #expect(DeviceStore(directory: folder).knownDevices.isEmpty)
    }
}
