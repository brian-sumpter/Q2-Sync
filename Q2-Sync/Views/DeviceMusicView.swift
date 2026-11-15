//
//  DeviceMusicView.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  The "Music" tab of the device page: choose "Entire music library" or
//  tick individual artists, albums, genres and playlists, like Finder's
//  iPod sync. A summary bar shows how many songs and bytes will sync and
//  how many will be skipped (cloud-only, protected, missing).
//
//  HOW IT FITS
//  Reads the library snapshot from `LibraryModel`, reads and saves the
//  selection through `DeviceMonitor` (stored per device), and uses
//  `SelectionResolver` (Core) for the summary. The summary bar holds the
//  Sync button, and `CapacityBarView` sits above it.
//

import SwiftUI

/// Choose what to sync to the Q2.
struct DeviceMusicView: View {

    let connected: ConnectedDevice
    let devices: DeviceMonitor
    let library: LibraryModel

    /// Which section's checkboxes are showing.
    @State private var section: BrowseCategory = .artists

    /// Text typed in the filter field.
    @State private var filterText = ""

    /// Controls the skipped-songs popover.
    @State private var showingSkipped = false

    /// Runs syncs (from the environment, set up in `Q2SyncApp`).
    @Environment(SyncCoordinator.self) private var sync

    /// Starts syncs the same way the menu bar does.
    @Environment(AutoSyncController.self) private var autoSync

    /// The saved selection for this device.
    private var selection: SyncSelection { connected.device.effectiveSelection }

    var body: some View {
        if let snapshot = library.snapshot {
            content(snapshot: snapshot)
        } else {
            VStack(spacing: 0) {
                ContentUnavailableView {
                    Label("Library Not Read Yet", systemImage: "music.note.house")
                } description: {
                    Text("Read your Apple Music library to choose what to sync. Q2 Sync only reads it and never changes anything.")
                } actions: {
                    Button("Read Library") { Task { await library.load() } }
                        .disabled(library.state == .loading)
                }
                Divider()
                // Current card usage, before any selection is known.
                CapacityBarView(estimate: capacity(for: nil))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        }
    }

    /// Capacity numbers for the connected card and a selection.
    ///
    /// - Parameter resolved: The resolved selection, or `nil` before the
    ///   library has been read.
    private func capacity(for resolved: ResolvedSelection?) -> CapacityEstimate {
        CapacityEstimate.compute(totalBytes: connected.volume.totalCapacity ?? 0,
                                 freeBytes: connected.volume.availableCapacity ?? 0,
                                 manifest: devices.cardManifest,
                                 selection: resolved)
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(snapshot: LibrarySnapshot) -> some View {
        let resolved = SelectionResolver.resolve(selection, in: snapshot)

        VStack(alignment: .leading, spacing: 0) {
            // "Entire library" vs "Selected items", like Finder.
            Picker("Sync", selection: Binding(
                get: { selection.mode },
                set: { mode in update { $0.mode = mode } })) {
                Text("Entire music library").tag(SyncSelection.Mode.entireLibrary)
                Text("Selected artists, albums, genres, and playlists").tag(SyncSelection.Mode.selectedItems)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if selection.mode == .selectedItems {
                sectionPicker
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                checklist(snapshot: snapshot)
            } else {
                ContentUnavailableView("Your Entire Library",
                                       systemImage: "music.note.list",
                                       description: Text("Every song and playlist that can be copied will be synced."))
                    // Fill the space so the capacity and Sync bars sit at the bottom.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            // Finder-style bar: what the card holds and what this sync adds.
            CapacityBarView(estimate: capacity(for: resolved))
                .padding(.horizontal, 20)
                .padding(.top, 10)
            summaryBar(resolved)
        }
    }

    // MARK: - Section picker and filter

    /// Segmented control for the four sections, plus a filter field.
    private var sectionPicker: some View {
        HStack {
            Picker("Section", selection: $section) {
                ForEach(BrowseCategory.allCases) { category in
                    Text(sectionTitle(category)).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            TextField("Filter", text: $filterText, prompt: Text("Filter \(section.rawValue)"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
        .onChange(of: section) { filterText = "" }
    }

    /// e.g. "Artists" or "Artists (3)" when some are ticked.
    private func sectionTitle(_ category: BrowseCategory) -> String {
        let count = tickedIDs(for: category).count
        return count > 0 ? "\(category.rawValue) (\(count))" : category.rawValue
    }

    // MARK: - Checklist

    /// The checkbox list for the current section.
    @ViewBuilder
    private func checklist(snapshot: LibrarySnapshot) -> some View {
        let rows = filteredRows(snapshot: snapshot)
        if rows.isEmpty {
            ContentUnavailableView.search(text: filterText)
        } else {
            List(rows) { row in
                Toggle(isOn: binding(for: row.id)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                            if let subtitle = row.subtitle {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(row.trackIDs.count, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    /// The current section's rows, filtered by the filter text.
    ///
    /// For playlists the group ID is `"playlist:<id>"`; we keep that
    /// format in the list and strip the prefix when saving.
    private func filteredRows(snapshot: LibrarySnapshot) -> [TrackGroup] {
        let rows = section.groups(in: snapshot).map { group -> TrackGroup in
            guard section == .playlists else { return group }
            // Show the folder a playlist lives in as its subtitle.
            let playlistID = String(group.id.dropFirst("playlist:".count))
            let folderName = snapshot.playlists.first { $0.id == playlistID }?.parentID
                .flatMap { parent in snapshot.playlists.first { $0.id == parent }?.name }
            let subtitle = [group.subtitle, folderName.map { "in \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            return TrackGroup(id: group.id, title: group.title,
                              subtitle: subtitle.isEmpty ? nil : subtitle, trackIDs: group.trackIDs)
        }
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// The saved IDs for a section, in the form the list rows use.
    private func tickedIDs(for category: BrowseCategory) -> Set<String> {
        switch category {
        case .artists:   return selection.artistIDs
        case .albums:    return selection.albumIDs
        case .genres:    return selection.genreIDs
        case .playlists: return Set(selection.playlistIDs.map { "playlist:\($0)" })
        }
    }

    /// A checkbox binding: reads whether `rowID` is ticked, and saves
    /// the change through `DeviceMonitor` when clicked.
    private func binding(for rowID: String) -> Binding<Bool> {
        Binding(
            get: { tickedIDs(for: section).contains(rowID) },
            set: { isOn in
                let category = section
                update { selection in
                    switch category {
                    case .artists:   selection.artistIDs.toggle(rowID, on: isOn)
                    case .albums:    selection.albumIDs.toggle(rowID, on: isOn)
                    case .genres:    selection.genreIDs.toggle(rowID, on: isOn)
                    case .playlists:
                        selection.playlistIDs.toggle(String(rowID.dropFirst("playlist:".count)), on: isOn)
                    }
                }
            }
        )
    }

    /// Applies a change to the selection and saves it.
    ///
    /// - Parameter change: A closure that edits a copy of the selection.
    ///   `inout` lets the closure modify the copy in place.
    private func update(_ change: (inout SyncSelection) -> Void) {
        var copy = selection
        change(&copy)
        devices.setSelection(copy)
    }

    // MARK: - Summary bar

    /// "1,234 songs · 8.2 GB · 32 skipped" plus Deselect All.
    private func summaryBar(_ resolved: ResolvedSelection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
            Text("\(resolved.tracksToSync.count.formatted()) songs")
                .fontWeight(.medium)
            Text(Int64(resolved.totalBytes).formatted(ByteCountFormatStyle(style: .file)))
                .foregroundStyle(.secondary)
            if !resolved.playlists.isEmpty {
                Text("\(resolved.playlists.count) playlists").foregroundStyle(.secondary)
            }

            if !resolved.skippedTracks.isEmpty {
                Button {
                    showingSkipped = true
                } label: {
                    Label("\(resolved.skippedTracks.count.formatted()) can't be synced",
                          systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.link)
                .popover(isPresented: $showingSkipped, arrowEdge: .top) {
                    SkippedSummaryView(resolved: resolved)
                }
            }

            Spacer()

            if selection.mode == .selectedItems && selection.tickedItemCount > 0 {
                Button("Deselect All") {
                    update { $0 = SyncSelection(mode: .selectedItems) }
                }
            }

            Button {
                Task { await autoSync.startSync(automatic: false) }
            } label: {
                Label(connected.device.hasCompletedDryRun == true ? "Sync" : "Preview Sync",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .disabled(sync.phase != .idle || connected.accessURL == nil)
            .help(connected.device.hasCompletedDryRun == true
                  ? "Preview the changes, then copy them to the Q2"
                  : "Your first sync is a preview: nothing on the card changes")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Popover explaining which selected songs can't be synced, and why.
struct SkippedSummaryView: View {

    let resolved: ResolvedSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Some selected songs can't be synced")
                .font(.headline)
            ForEach(TrackAvailability.allCases, id: \.self) { kind in
                if let count = resolved.skippedCounts[kind] {
                    Label("\(kind.reportDescription): \(count.formatted())", systemImage: kind.symbolName)
                        .foregroundStyle(kind.tint)
                }
            }
            Text("Q2 Sync never downloads songs from iCloud. To include cloud songs, download them in Music first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 320)
    }
}

extension Set {
    /// Inserts or removes an element depending on `on`. Makes checkbox
    /// code read naturally: `ids.toggle(id, on: isChecked)`.
    mutating func toggle(_ element: Element, on: Bool) {
        if on { insert(element) } else { remove(element) }
    }
}
