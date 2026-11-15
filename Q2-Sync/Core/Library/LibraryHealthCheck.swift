//
//  LibraryHealthCheck.swift
//  Q2-Sync › Core › Library
//
//  PURPOSE
//  The "Mac looks empty" guard. Before any sync is planned, this check
//  decides whether the library snapshot can be trusted as the source of
//  truth.
//
//  WHY IT MATTERS
//  If the library failed to load properly, or the external drive holding
//  the music is unplugged, the Mac might *look* like it has no songs. A
//  naive sync would then think every song on the card should be removed.
//  This check stops that from ever happening: an untrustworthy library
//  aborts the sync before anything is planned.
//
//  HOW IT FITS
//  The SyncEngine calls `LibraryHealthCheck.evaluate(_:)` first and refuses
//  to continue on any `.unsafe` result. The UI also shows the result.
//

import Foundation

/// The outcome of checking a library snapshot.
enum LibraryHealth: Equatable, Sendable {
    /// The library looks normal; syncing may proceed.
    case healthy

    /// The library can't be trusted. Syncing must stop. The string is a
    /// user-facing explanation.
    case unsafe(String)

    /// `true` if syncing may proceed.
    var isHealthy: Bool { self == .healthy }
}

/// Decides whether a library snapshot is trustworthy enough to sync from.
enum LibraryHealthCheck {

    /// If more than this fraction of local (non-cloud, non-DRM) tracks are
    /// missing on disk, assume a drive is disconnected and stop.
    static let maximumMissingFraction = 0.10

    /// Checks a snapshot.
    ///
    /// - Parameters:
    ///   - snapshot: The library snapshot to check.
    ///   - fileManager: Used to check the media folder is reachable.
    ///     Injectable so tests can use temp folders.
    /// - Returns: `.healthy`, or `.unsafe` with the reason.
    /// - Side effects: None. Only checks whether a folder exists.
    static func evaluate(_ snapshot: LibrarySnapshot, fileManager: FileManager = .default) -> LibraryHealth {
        // Rule 1: zero tracks means something is wrong, not "delete everything".
        guard !snapshot.tracks.isEmpty else {
            return .unsafe("Your Apple Music library appears to have no songs. "
                + "Nothing will be synced, so nothing on the card is removed.")
        }

        // Rule 2: the media folder must be present (it may live on an
        // external drive that's currently disconnected).
        if let mediaFolder = snapshot.mediaFolderURL {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: mediaFolder.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                return .unsafe("Your Apple Music media folder isn't available "
                    + "(\(mediaFolder.path)). If your music is on an external drive, connect it and try again.")
            }
        }

        // Rule 3: lots of files missing also suggests a disconnected drive.
        let counts = snapshot.availabilityCounts
        let missing = counts[.fileMissing, default: 0]
        let local = missing + counts[.available, default: 0]
        if local > 0 {
            let fraction = Double(missing) / Double(local)
            if fraction > maximumMissingFraction {
                let percent = Int((fraction * 100).rounded())
                return .unsafe("\(percent)% of your songs' files can't be found on disk. "
                    + "If your music is on an external drive, connect it and try again.")
            }
        }

        return .healthy
    }
}
