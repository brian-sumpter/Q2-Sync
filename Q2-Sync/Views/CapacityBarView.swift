//
//  CapacityBarView.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  The Finder-style capacity bar at the bottom of the Music tab: one bar
//  split into coloured parts (other files, your synced music, music that's
//  no longer selected, music the sync would add, free space), a legend
//  with sizes, and a warning when the selection won't fit.
//
//  HOW IT FITS
//  `DeviceMusicView` builds a `CapacityEstimate` (Core) from the card's
//  manifest, free space and the current selection, and passes it here.
//  This view only draws it.
//

import SwiftUI

/// Draws a `CapacityEstimate` as a segmented bar with a legend.
struct CapacityBarView: View {

    let estimate: CapacityEstimate

    /// One coloured part of the bar.
    private struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
    }

    /// The parts, in Finder's left-to-right order. Empty parts are dropped.
    private var segments: [Segment] {
        [
            Segment(id: "music", label: "Music", bytes: estimate.selectedMusicBytes, color: .blue),
            Segment(id: "deselected", label: "Not selected", bytes: estimate.deselectedMusicBytes, color: .blue.opacity(0.4)),
            Segment(id: "add", label: "To add", bytes: estimate.toAddBytes, color: .green),
            Segment(id: "other", label: "Other", bytes: estimate.otherBytes, color: .yellow),
            Segment(id: "free", label: "Free", bytes: max(0, estimate.freeAfterBytes), color: .secondary.opacity(0.15)),
        ].filter { $0.bytes > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar
            legend
            status
        }
        .accessibilityElement(children: .combine)
    }

    /// The bar itself. `GeometryReader` gives us the available width so
    /// each part can be sized in proportion to its bytes.
    private var bar: some View {
        GeometryReader { geometry in
            let total = max(1, segments.reduce(Int64(0)) { $0 + $1.bytes })
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        // Tiny parts stay visible as a 2-point sliver.
                        .frame(width: max(2, geometry.size.width * CGFloat(segment.bytes) / CGFloat(total)))
                }
            }
            .clipShape(.rect(cornerRadius: 5))
        }
        .frame(height: 18)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }

    /// Coloured dots with labels and sizes, e.g. "● Music 266.6 MB".
    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(segments) { segment in
                HStack(spacing: 4) {
                    Circle().fill(segment.color).frame(width: 8, height: 8)
                    Text(segment.label).foregroundStyle(.primary)
                    Text(Self.format(segment.bytes)).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }

    /// A warning when the selection doesn't fit.
    @ViewBuilder
    private var status: some View {
        switch estimate.fit {
        case .fits:
            EmptyView()
        case .fitsIfRemovingDeselected:
            Label("This only fits if you remove the songs you deselected (you can choose that in the sync preview).",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .doesNotFit(let shortBy):
            Label("Your selection doesn't fit on the card. Deselect about \(Self.format(shortBy)) of music.",
                  systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private static func format(_ bytes: Int64) -> String {
        bytes.formatted(ByteCountFormatStyle(style: .file))
    }
}

#Preview {
    CapacityBarView(estimate: CapacityEstimate(
        totalBytes: 256_000_000_000, freeBytes: 230_000_000_000,
        selectedMusicBytes: 20_000_000_000, deselectedMusicBytes: 2_000_000_000,
        otherBytes: 4_000_000_000, toAddBytes: 8_000_000_000, fit: .fits))
        .padding()
        .frame(width: 600)
}
