//
//  SyncLog.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Writes a plain-text log of every sync: each add, update, move, removal
//  (and later, each copy-back), with a summary. Dry runs are logged too,
//  marked "DRY RUN", listing what WOULD happen.
//
//  WHERE
//  On the Mac, in the app's sandbox container:
//    ~/Library/Containers/io.github.q2sync.Q2Sync/Data/Library/
//        Application Support/Q2 Sync/Logs/Sync 2026-11-15 at 15.30.00.log
//  (The Settings tab will get a "Show Logs" button.)
//
//  Each line is written and flushed immediately, so the log is complete
//  up to the moment of any crash or cancel.
//

import Foundation

/// An append-only text log for one sync.
final class SyncLog {

    /// The log file.
    let fileURL: URL

    /// Open handle to the log file.
    private let handle: FileHandle?

    /// Formats timestamps at the start of each line.
    private let timeFormat = Date.FormatStyle(date: .omitted, time: .standard)

    /// The folder holding all sync logs.
    static var logsDirectory: URL {
        DeviceStore.defaultDirectory.appending(path: "Logs", directoryHint: .isDirectory)
    }

    /// A file-name-friendly timestamp in 24-hour time, e.g.
    /// "2026-11-15 at 13.19.51". A fixed format (not the user's locale) so
    /// names sort correctly and never contain ":" (not allowed on FAT).
    static func timestamp(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    /// Creates a new log file and writes its header.
    ///
    /// - Parameters:
    ///   - title: e.g. "Sync" or "Dry run".
    ///   - deviceName: The Q2's name.
    ///   - directory: Where to write (tests pass a temp folder).
    init(title: String, deviceName: String, directory: URL = SyncLog.logsDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "\(title) \(Self.timestamp()).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        write("Q2 Sync — \(title) for “\(deviceName)” — \(Date.now.formatted(date: .complete, time: .standard))")
        write(String(repeating: "-", count: 72))
    }

    deinit { try? handle?.close() }

    /// Appends one timestamped line.
    func write(_ line: String) {
        let text = "\(Date.now.formatted(timeFormat))  \(line)\n"
        try? handle?.write(contentsOf: Data(text.utf8))
    }

    /// Logs every operation in a plan, prefixed (e.g. "WOULD ADD" for a dry run).
    ///
    /// - Parameters:
    ///   - plan: The plan to describe.
    ///   - dryRun: `true` to prefix lines with "WOULD".
    func describe(_ plan: SyncPlan, dryRun: Bool) {
        let would = dryRun ? "WOULD " : ""
        for copy in plan.copies {
            let verb = copy.kind == .add ? "ADD" : "UPDATE"
            let reason = copy.reason.map { " — \($0)" } ?? ""
            write("\(would)\(verb)  \(copy.destination)  (\(Self.size(copy.track.fileSize)))\(reason)")
        }
        for move in plan.moves { write("\(would)MOVE  \(move.from)  →  \(move.to)") }
        for adoption in plan.adoptions { write("\(would)ADOPT  \(adoption.path)  (already on card)") }
        for removal in plan.removals { write("\(would)REMOVE  \(removal.entry.path)") }
        for playlist in plan.playlistPlan.writes { write("\(would)WRITE PLAYLIST  \(playlist.path)") }
        for removal in plan.playlistPlan.removals { write("\(would)REMOVE PLAYLIST  \(removal.path)") }
        for playlist in plan.playlistPlan.overLimit {
            write("SKIP PLAYLIST  \(playlist.name): over the Q2's playlist limit")
        }
        for item in plan.cardOnly {
            let note = item.origin == .unmanaged ? "not put there by Q2 Sync" : "no longer in your library"
            write("CARD-ONLY  \(item.path)  (\(note))")
        }
        for track in plan.skipped {
            write("SKIP  \(track.displayArtist) — \(track.title): \(track.availability.reportDescription)")
        }
    }

    /// "5.2 MB" style sizes; "nothing" for zero (instead of "Zero kB").
    static func size(_ bytes: UInt64) -> String {
        bytes == 0 ? "nothing" : Int64(bytes).formatted(ByteCountFormatStyle(style: .file))
    }
}
