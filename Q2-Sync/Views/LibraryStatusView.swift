//
//  LibraryStatusView.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  A compact status box at the bottom of the sidebar that summarises the
//  library: loading spinner, error, song counts by availability, and the
//  result of the "Mac looks empty" safety check.
//
//  HOW IT FITS
//  Displayed at the bottom of the sidebar by `RootView`. Reads `LibraryModel` only.
//

import SwiftUI

/// Sidebar footer summarising the library's state.
struct LibraryStatusView: View {

    /// The model to summarise.
    let library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch library.state {
            case .idle:
                Label("Library not read", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading library…")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .loaded:
                loadedSummary
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    /// Counts and health once a snapshot exists.
    @ViewBuilder
    private var loadedSummary: some View {
        if let snapshot = library.snapshot {
            let counts = snapshot.availabilityCounts
            Text("\(snapshot.tracks.count.formatted()) songs · \(snapshot.playlists.count.formatted()) playlists")
                .fontWeight(.medium)

            // Show every category that isn't zero, e.g. "Cloud only: 12".
            ForEach(TrackAvailability.allCases, id: \.self) { kind in
                if let count = counts[kind], count > 0 {
                    HStack {
                        Image(systemName: kind.symbolName).foregroundStyle(kind.tint)
                        Text("\(kind.shortName): \(count.formatted())")
                    }
                }
            }

            if let health = library.health {
                switch health {
                case .healthy:
                    Label("Library looks healthy", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                case .unsafe(let reason):
                    Label(reason, systemImage: "xmark.shield")
                        .foregroundStyle(.red)
                }
            }

            if let duration = library.lastLoadDuration {
                Text("Read in \(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Presentation helpers for availability

extension TrackAvailability {

    /// A short label for lists, e.g. "Cloud only".
    var shortName: String {
        switch self {
        case .available:    return "Ready to sync"
        case .cloudOnly:    return "Cloud only"
        case .drmProtected: return "Protected"
        case .fileMissing:  return "Missing file"
        case .unsupported:  return "Unsupported"
        }
    }

    /// SF Symbol shown next to the label.
    var symbolName: String {
        switch self {
        case .available:    return "checkmark.circle.fill"
        case .cloudOnly:    return "icloud"
        case .drmProtected: return "lock.fill"
        case .fileMissing:  return "questionmark.folder"
        case .unsupported:  return "nosign"
        }
    }

    /// Accent colour for the symbol.
    var tint: Color {
        switch self {
        case .available:    return .green
        case .cloudOnly:    return .blue
        case .drmProtected: return .orange
        case .fileMissing:  return .red
        case .unsupported:  return .secondary
        }
    }
}
