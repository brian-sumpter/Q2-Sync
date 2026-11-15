//
//  VolumeInfo.swift
//  Q2-Sync › Core › Device
//
//  PURPOSE
//  Describes a mounted disk (volume): its unique ID, name, size, format,
//  and whether it's removable or internal. Also decides whether a volume is
//  even *allowed* to be treated as a Q2 card.
//
//  HOW IT FITS
//  `DeviceMonitor` (App) builds a `VolumeInfo` for each mounted volume and
//  asks `VolumeEligibility` whether it could be a Q2. Later, `PathGuard`
//  re-checks the same rules before every write, so a mistake elsewhere
//  can't turn an internal disk into a sync target.
//

import Foundation

/// Facts about one mounted volume, read from the file system.
struct VolumeInfo: Hashable, Sendable, Identifiable {

    /// The volume's mount point, e.g. `/Volumes/Q2CARD`.
    let url: URL

    /// The file system's unique ID (a UUID string). For FAT/exFAT cards
    /// macOS derives it from the card's serial number, so it stays the same
    /// across reconnects but changes if the card is reformatted.
    let uuid: String?

    /// The volume's name as shown in Finder.
    let name: String

    /// `true` if the media can be removed (SD cards, USB players).
    let isRemovable: Bool

    /// `true` if macOS offers to eject it.
    let isEjectable: Bool

    /// `true` if the *device* is inside the Mac. Note: a Mac's built-in SD
    /// card slot reports internal = true but removable = true.
    let isInternal: Bool

    /// `true` for the startup disk.
    let isRootFileSystem: Bool

    /// File system name, e.g. "ExFAT" or "MS-DOS (FAT32)".
    let formatDescription: String?

    /// Total size in bytes.
    let totalCapacity: Int64?

    /// Free space in bytes ("important usage" accounts for purgeable space).
    let availableCapacity: Int64?

    /// SwiftUI identity: the UUID if there is one, otherwise the path.
    var id: String { uuid ?? url.path }

    /// `true` if the format is one the Q2 supports (exFAT or FAT32).
    var isFATFamily: Bool {
        guard let format = formatDescription?.lowercased() else { return false }
        return format.contains("exfat") || format.contains("fat") || format.contains("ms-dos")
    }

    /// Reads volume facts from the file system.
    ///
    /// - Parameter url: A volume's mount point.
    /// - Returns: The facts, or `nil` if they can't be read.
    /// - Side effects: None. Reads metadata only; never lists or opens files.
    static func read(at url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeNameKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
            .volumeIsRootFileSystemKey, .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeInfo(
            url: url,
            uuid: values.volumeUUIDString,
            name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isInternal: values.volumeIsInternal ?? true, // Unknown? Assume internal: the safe choice.
            isRootFileSystem: values.volumeIsRootFileSystem ?? false,
            formatDescription: values.volumeLocalizedFormatDescription,
            totalCapacity: values.volumeTotalCapacity.map(Int64.init),
            availableCapacity: bestAvailableCapacity(
                importantUsage: values.volumeAvailableCapacityForImportantUsage,
                plain: values.volumeAvailableCapacity)
        )
    }

    /// Picks the most trustworthy free-space figure.
    ///
    /// macOS offers two: "available for important usage" (which counts
    /// purgeable space on APFS) and plain "available". On exFAT/FAT cards
    /// the first one comes back as 0 instead of `nil`, which made a 256 GB
    /// empty card look full. So we take the larger of the two known values.
    ///
    /// - Parameters:
    ///   - importantUsage: `volumeAvailableCapacityForImportantUsage`, if any.
    ///   - plain: `volumeAvailableCapacity`, if any.
    /// - Returns: Free bytes, or `nil` if neither is known.
    static func bestAvailableCapacity(importantUsage: Int64?, plain: Int?) -> Int64? {
        let candidates = [importantUsage, plain.map(Int64.init)].compactMap { $0 }
        return candidates.max()
    }
}

/// Why a volume can't be used as a Q2 card.
enum VolumeIneligibility: Equatable, Sendable {
    case startupDisk
    case internalFixedDisk
    case notRemovable
    case noUUID
    case unsupportedFormat(String)

    /// User-facing explanation.
    var explanation: String {
        switch self {
        case .startupDisk:       return "This is your Mac's startup disk."
        case .internalFixedDisk: return "This is an internal disk."
        case .notRemovable:      return "This disk isn't removable."
        case .noUUID:            return "This disk has no unique ID, so it can't be recognised reliably."
        case .unsupportedFormat(let format):
            return "This disk is formatted as \(format). The Q2 needs exFAT or FAT32."
        }
    }
}

/// The rules for which volumes may ever be treated as a Q2 card.
///
/// These are deliberately strict: it's far better to ignore a real Q2 than
/// to ever write to the wrong disk.
enum VolumeEligibility {

    /// Checks whether a volume may be a Q2 card.
    ///
    /// Rules:
    ///   1. Never the startup disk.
    ///   2. Must be removable or ejectable media.
    ///   3. Internal is only OK when the media itself is removable (a Mac's
    ///      built-in SD card slot). Internal fixed disks are always refused.
    ///   4. Must have a UUID, so we can recognise it next time.
    ///   5. Must be exFAT or FAT, the only formats the Q2 reads.
    ///
    /// - Parameter volume: The volume to check.
    /// - Returns: `nil` if eligible, otherwise the first reason it isn't.
    static func problem(with volume: VolumeInfo) -> VolumeIneligibility? {
        if volume.isRootFileSystem { return .startupDisk }
        if volume.isInternal && !volume.isRemovable { return .internalFixedDisk }
        if !volume.isRemovable && !volume.isEjectable { return .notRemovable }
        if volume.uuid == nil { return .noUUID }
        if !volume.isFATFamily { return .unsupportedFormat(volume.formatDescription ?? "an unknown format") }
        return nil
    }

    /// `true` if the volume may be a Q2 card.
    static func isEligible(_ volume: VolumeInfo) -> Bool { problem(with: volume) == nil }
}
