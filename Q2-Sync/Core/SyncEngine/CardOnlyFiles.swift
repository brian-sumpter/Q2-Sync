//
//  CardOnlyFiles.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Finds music on the card that isn't part of what you sync from the Mac
//  ("card-only" music), so you can decide, item by item, what happens to
//  each one. Nothing is ever deleted automatically.
//
//  TWO KINDS OF CARD-ONLY MUSIC
//  1. Unmanaged files: audio files Q2 Sync didn't put there (copied by
//     hand, from another app, an old sync tool…), anywhere on the card
//     except reserved items, the app's own `.q2sync` folder and the
//     playlist folder.
//  2. Songs Q2 Sync synced earlier whose track has since disappeared from
//     your Mac library. The card might hold the only copy, so they're
//     offered here (with "Copy to Mac") rather than as plain removals.
//
//  THE CHOICES
//  Leave (the default) · Copy to Mac · Move to Card Trash · Delete.
//
//  HOW IT FITS
//      card scan + manifest ──▶ CardOnlyFinder ──▶ [CardOnlyItem]
//      AudioTagReader fills in tags ──▶ preview lists them with a choice each
//      SyncExecutor applies the choices (copy-backs through RecoveryCopier)
//

import AVFoundation
import Foundation

/// What to do with one card-only file.
enum CardOnlyAction: String, Sendable, CaseIterable, Identifiable, Codable {
    case leave
    case copyToMac
    case moveToTrash
    case delete

    var id: String { rawValue }

    /// Label for menus.
    var title: String {
        switch self {
        case .leave:       return "Leave on Card"
        case .copyToMac:   return "Copy to Mac"
        case .moveToTrash: return "Move to Card Trash"
        case .delete:      return "Delete from Card"
        }
    }

    /// `true` if the file leaves the card's music.
    var removesFromCard: Bool { self == .moveToTrash || self == .delete }
}

/// One card-only music file.
struct CardOnlyItem: Sendable, Hashable, Identifiable {

    /// Where it came from.
    enum Origin: Sendable, Hashable {
        /// Not put there by Q2 Sync.
        case unmanaged
        /// Synced by Q2 Sync earlier; its track is no longer in your library.
        case removedFromLibrary(trackID: PersistentID)
    }

    let path: CardPath
    let size: UInt64
    let origin: Origin
    /// Tags, if they could be read (or from the manifest for synced songs).
    var title: String?
    var artist: String?
    var album: String?
    var durationSeconds: Double?
    /// `true` if your library has this song as a local file already
    /// (matched by title, artist and length). Copying it back is skipped.
    var isInLibrary = false

    var id: CardPath { path }

    /// e.g. "Adele — Hello", or the file name when untagged.
    var displayName: String {
        guard let title else { return (path as NSString).lastPathComponent }
        return [artist, title].compactMap { $0 }.joined(separator: " — ")
    }
}

/// Finds card-only music.
enum CardOnlyFinder {

    /// Lists card-only files.
    ///
    /// - Parameters:
    ///   - allCardFiles: Every non-reserved file on the card (whole-card scan).
    ///   - manifest: Songs Q2 Sync manages.
    ///   - orphanedEntries: Managed songs whose track left the library.
    ///   - profile: Folder names.
    /// - Returns: Items sorted by path.
    static func find(allCardFiles: [String: CardFile], manifest: SyncManifest,
                     orphanedEntries: [RemoveOperation], profile: DeviceProfile) -> [CardOnlyItem] {
        let managedKeys = Set(manifest.entries.values.map { CardLayout.caseKey($0.path) })
        let skippedTopFolders: Set<String> = [profile.appStateFolderName.lowercased(),
                                              profile.playlistFolderName.lowercased()]
        var items: [CardOnlyItem] = []

        // 1. Unmanaged audio files.
        for (key, file) in allCardFiles where !managedKeys.contains(key) {
            let top = file.path.split(separator: "/").first.map { String($0).lowercased() } ?? ""
            guard !skippedTopFolders.contains(top) else { continue }
            let ext = (file.path as NSString).pathExtension.lowercased()
            guard CardScanner.audioExtensions.contains(ext) else { continue }
            items.append(CardOnlyItem(path: file.path, size: file.size, origin: .unmanaged))
        }

        // 2. Synced songs that left the library (only if still on the card).
        for orphan in orphanedEntries where allCardFiles[CardLayout.caseKey(orphan.entry.path)] != nil {
            items.append(CardOnlyItem(path: orphan.entry.path, size: orphan.entry.cardSize,
                                      origin: .removedFromLibrary(trackID: orphan.trackID),
                                      title: orphan.entry.title, artist: orphan.entry.artist,
                                      album: orphan.entry.album))
        }
        return items.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Marks items your library already has as LOCAL files (same title and
    /// artist, ignoring case, and length within 2 seconds). A cloud-only
    /// match doesn't count: then the card copy may be the only file.
    static func markLibraryMatches(_ items: inout [CardOnlyItem], snapshot: LibrarySnapshot) {
        var index: [String: [Track]] = [:]
        for track in snapshot.tracks where track.isCopyable {
            index[matchKey(title: track.title, artist: track.artist), default: []].append(track)
        }
        for i in items.indices {
            guard let title = items[i].title,
                  let candidates = index[matchKey(title: title, artist: items[i].artist)] else { continue }
            if let duration = items[i].durationSeconds {
                items[i].isInLibrary = candidates.contains { abs($0.durationSeconds - duration) <= 2 }
            } else {
                items[i].isInLibrary = false // Without a length we can't be sure.
            }
        }
    }

    private static func matchKey(title: String, artist: String?) -> String {
        "\(title.lowercased())|\((artist ?? "").lowercased())"
    }
}

/// Reads basic tags from an audio file (read-only), using AVFoundation.
enum AudioTagReader {

    /// Fills in title, artist, album and length for items that lack them.
    ///
    /// - Parameters:
    ///   - items: Items to complete.
    ///   - cardRoot: The card root, to build file URLs.
    /// - Side effects: Opens each file for reading only.
    static func fillTags(_ items: inout [CardOnlyItem], cardRoot: URL) async {
        for i in items.indices {
            let url = cardRoot.appending(path: items[i].path)
            let asset = AVURLAsset(url: url)
            // `try?` turns any failure (unreadable or unsupported file) into
            // nil, so one odd file can't stop the scan.
            guard let (metadata, duration) = try? await asset.load(.commonMetadata, .duration) else { continue }
            items[i].durationSeconds = duration.seconds.isFinite ? duration.seconds : items[i].durationSeconds
            if items[i].title == nil {
                items[i].title = await string(.commonIdentifierTitle, in: metadata)
                items[i].artist = await string(.commonIdentifierArtist, in: metadata)
                items[i].album = await string(.commonIdentifierAlbumName, in: metadata)
            }
        }
    }

    /// The first string value for a metadata identifier, if any.
    private static func string(_ identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> String? {
        let matches = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
        guard let item = matches.first else { return nil }
        return (try? await item.load(.stringValue))?.nonEmpty
    }
}
