//
//  TrackTableView.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  A sortable, Finder-style table of tracks showing tags, duration,
//  availability and the source file path on your Mac (handy for checking
//  what ITLibrary reports).
//
//  HOW IT FITS
//  Shown on the right of `LibraryCategoryView`.
//

import SwiftUI

/// A table of tracks.
struct TrackTableView: View {

    /// The tracks to show, in their natural (album/playlist) order.
    let tracks: [Track]

    /// The table's current sort, changed by clicking column headers.
    /// Empty means "keep the natural order".
    @State private var sortOrder: [KeyPathComparator<Track>] = []

    /// Tracks in the order the user asked for.
    private var sortedTracks: [Track] {
        sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedTracks, sortOrder: $sortOrder) {
            TableColumn("#") { track in
                Text(track.trackNumber > 0 ? "\(track.trackNumber)" : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(28)

            TableColumn("Title", value: \.title)

            TableColumn("Artist", value: \.displayArtist)

            TableColumn("Album", value: \.displayAlbum)

            TableColumn("Time", value: \.durationSeconds) { track in
                Text(Duration.seconds(track.durationSeconds)
                        .formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
            }
            .width(50)

            TableColumn("Status") { track in
                Label(track.availability.shortName, systemImage: track.availability.symbolName)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(track.availability.tint)
                    .help(track.availability.reportDescription)
            }
            .width(44)

            TableColumn("File") { track in
                Text(track.fileURL?.path ?? "—")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(track.fileURL?.path ?? "No local file")
                    .textSelection(.enabled)
            }
        }
    }
}

#Preview {
    TrackTableView(tracks: [])
}
