//
//  SyncSheet.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  The sheet that walks through a sync: "Preparing…", then the preview of
//  what will change (with removal choices and safety warnings), then
//  progress with Cancel, then the result with the "update the library on
//  your Q2" reminder.
//
//  HOW IT FITS
//  Presented by `RootView` whenever `SyncCoordinator.phase` isn't idle.
//  Each phase has its own small view below.
//

import AppKit
import SwiftUI

/// Switches between the sync phases.
struct SyncSheet: View {

    let sync: SyncCoordinator
    let devices: DeviceMonitor

    var body: some View {
        Group {
            switch sync.phase {
            case .idle:
                EmptyView()
            case .planning(let message):
                VStack(spacing: 14) {
                    ProgressView()
                    Text(message)
                    Button("Cancel") { sync.close() }
                }
                .padding(32)
                .frame(width: 360)
            case .preview:
                if let preview = sync.preview {
                    SyncPreviewView(preview: preview, sync: sync, devices: devices)
                }
            case .running:
                SyncProgressView(sync: sync)
            case .finished:
                if let report = sync.report {
                    SyncResultView(report: report, profile: sync.preview?.profile ?? .q2Pod,
                                   sync: sync, devices: devices)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 14) {
                    Label("Sync Stopped", systemImage: "xmark.octagon.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.red)
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("OK") { sync.close() }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
                .frame(width: 440)
            }
        }
        .interactiveDismissDisabled()
    }
}

// MARK: - Preview

/// Shows what a sync would do and lets the user apply it.
struct SyncPreviewView: View {

    let preview: SyncPreview
    let sync: SyncCoordinator
    let devices: DeviceMonitor

    /// Shows the "remove more than 20%?" confirmation.
    @State private var confirmingLargeRemoval = false

    /// Shows the "permanently delete card-only files?" confirmation.
    @State private var confirmingDeletes = false

    /// Filters every list in the preview (title, artist, album or path).
    @State private var searchText = ""

    /// Sections the user opened or closed, by section ID. Sections the user
    /// hasn't touched use `defaultExpanded(_:count:)`.
    @State private var expansion: [String: Bool] = [:]

    /// Sections with more items than this start collapsed, so a first sync
    /// of thousands of songs doesn't bury the sections that need attention.
    private static let collapseThreshold = 200

    private var plan: SyncPlan { preview.plan }
    private var assessment: SafetyAssessment { preview.assessment(for: sync.options) }

    /// Removal percentage for the user's current choices.
    private var removalPercent: Int {
        Int((plan.removalFraction(cardOnlyActions: sync.options.cardOnlyActions,
                                  includeRemovals: sync.options.applyRemovals) * 100).rounded())
    }

    /// Card-only files set to "Delete from Card".
    private var cardOnlyDeleteCount: Int {
        plan.cardOnly.filter { sync.options.cardOnlyActions[$0.path] == .delete }.count
    }

    /// `true` if the user chose any action other than Leave for card-only files.
    private var hasCardOnlyWork: Bool {
        plan.cardOnly.contains { (sync.options.cardOnlyActions[$0.path] ?? .leave) != .leave }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
            Divider()
            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            details
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 660, height: 640)
        .confirmationDialog("Permanently delete \(cardOnlyDeleteCount) files from the card?",
                            isPresented: $confirmingDeletes) {
            Button("Delete \(cardOnlyDeleteCount) Files and Sync", role: .destructive) {
                continueApplying(deletesConfirmed: true)
            }
        } message: {
            Text("These files aren't in your Mac library selection and can't be recovered after deleting. Choose “Move to Card Trash” instead to keep a copy on the card.")
        }
        .confirmationDialog(largeRemovalTitle, isPresented: $confirmingLargeRemoval) {
            Button("Remove and Sync", role: .destructive) {
                sync.options.largeRemovalConfirmed = true
                sync.apply(devices: devices)
            }
        } message: {
            Text("This is more than you usually change. Check the list above. You can turn off removing songs and sync just the additions instead.")
        }
    }

    private var largeRemovalTitle: String {
        "Remove \(removalPercent)% of the songs on “\(preview.deviceName)”?"
    }

    /// Runs the confirmations in order (deletes, then large removals),
    /// then applies.
    private func continueApplying(deletesConfirmed: Bool = false) {
        if cardOnlyDeleteCount > 0 && !deletesConfirmed {
            confirmingDeletes = true
        } else if assessment.needsLargeRemovalConfirmation && !sync.options.largeRemovalConfirmed {
            confirmingLargeRemoval = true
        } else {
            sync.apply(devices: devices)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.isFirstSync ? "Preview of Your First Sync" : "Ready to Sync")
                .font(.title2.bold())

            if preview.isFirstSync {
                Label("Your first sync with a card is always a preview. Nothing has been changed. Review the list, then click Sync again to apply it.",
                      systemImage: "eye")
                    .foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Counts at a glance.
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    countCell("Add", addCount, "plus.circle.fill", .green)
                    countCell("Update", plan.copies.count - addCount, "arrow.triangle.2.circlepath", .blue)
                    countCell("Rename", plan.moves.count, "pencil.circle.fill", .purple)
                }
                GridRow {
                    countCell("Remove", plan.removals.count, "minus.circle.fill", .red)
                    countCell("Already on card", plan.unchangedCount + plan.adoptions.count, "checkmark.circle.fill", .secondary)
                    countCell("Can't sync", plan.skipped.count, "exclamationmark.circle.fill", .orange)
                }
                if !plan.playlistPlan.writes.isEmpty || !plan.playlistPlan.removals.isEmpty || !plan.cardOnly.isEmpty {
                    GridRow {
                        countCell("Playlists", plan.playlistPlan.writes.count, "music.note.list", .pink)
                        countCell("Remove playlists", plan.playlistPlan.removals.count, "minus.circle", .red)
                        countCell("On card only", plan.cardOnly.count, "sdcard", .teal)
                    }
                }
            }

            Text(spaceSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(assessment.blockers, id: \.self) { blocker in
                Label(blocker, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func countCell(_ title: String, _ count: Int, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text("\(title): \(Text(count.formatted()).bold())")
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    /// e.g. "Copies 1.2 GB · 230.4 GB free afterwards".
    private var spaceSummary: String {
        let style = ByteCountFormatStyle(style: .file)
        let copy = plan.bytesToCopy == 0 ? "Nothing to copy" : "Copies \(Int64(plan.bytesToCopy).formatted(style))"
        let free = max(0, assessment.projectedFreeBytes).formatted(style)
        return "\(copy) · about \(free) free on the card afterwards"
    }

    // MARK: Details

    private var addCount: Int { plan.copies.lazy.filter { $0.kind == .add }.count }

    /// A search box above the list.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by song, artist, album or path", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
        }
    }

    private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedSearch.isEmpty }

    /// `true` when the filter is empty or any field contains it.
    private func matches(_ fields: String?...) -> Bool {
        let query = trimmedSearch
        guard !query.isEmpty else { return true }
        return fields.contains { $0?.localizedStandardContains(query) == true }
    }

    private func matches(_ track: Track, _ path: String) -> Bool {
        matches(track.title, track.artist, track.albumArtist, track.album, path)
    }

    /// The plan's lists, narrowed by the filter.
    private struct FilteredLists {
        var removals: [RemoveOperation]
        var cardOnly: [CardOnlyItem]
        var playlistWrites: [PlannedPlaylist]
        var playlistRemovals: [PlaylistRemoval]
        var skipped: [Track]
        var adds: [CopyOperation]
        var updates: [CopyOperation]
        var moves: [MoveOperation]
        var adoptions: [AdoptOperation]

        var isEmpty: Bool {
            removals.isEmpty && cardOnly.isEmpty && playlistWrites.isEmpty && playlistRemovals.isEmpty
                && skipped.isEmpty && adds.isEmpty && updates.isEmpty && moves.isEmpty && adoptions.isEmpty
        }
    }

    private func filteredLists() -> FilteredLists {
        let playlists = plan.playlistPlan
        return FilteredLists(
            removals: plan.removals.filter { matches($0.entry.title, $0.entry.artist, $0.entry.album, $0.entry.path) },
            cardOnly: plan.cardOnly.filter { matches($0.title, $0.artist, $0.album, $0.path) },
            playlistWrites: playlists.writes.filter { matches($0.playlist.name, $0.nameOnDevice, $0.path) },
            playlistRemovals: playlists.removals.filter { matches($0.path) },
            skipped: plan.skipped.filter { matches($0, "") },
            adds: plan.copies.filter { $0.kind == .add && matches($0.track, $0.destination) },
            updates: plan.copies.filter { $0.kind == .update && matches($0.track, $0.destination) },
            moves: plan.moves.filter { matches($0.track, $0.from) || matches($0.to) },
            adoptions: plan.adoptions.filter { matches($0.track, $0.path) })
    }

    /// Every planned change, grouped, in a scrollable list. Sections that
    /// need a decision or explain a problem come first; long lists of
    /// routine copies come last and start collapsed when large.
    private var details: some View {
        let lists = filteredLists()
        return List {
            removalSection(lists.removals)
            cardOnlySection(lists.cardOnly)
            playlistSection(writes: lists.playlistWrites, removals: lists.playlistRemovals)
            collapsibleSection("skipped", "Can't Sync", lists.skipped, alwaysOpen: true) { track in
                row("\(track.displayArtist) — \(track.title)", detail: track.availability.reportDescription,
                    symbol: track.availability.symbolName, color: .orange)
            }
            collapsibleSection("update", "Update", lists.updates) { copy in
                row(copy.track.title, detail: "\(copy.destination) — \(copy.reason ?? "")",
                    symbol: "arrow.triangle.2.circlepath", color: .blue)
            }
            collapsibleSection("rename", "Rename", lists.moves) { move in
                row(move.track.title, detail: "\(move.from) → \(move.to)", symbol: "pencil.circle", color: .purple)
            }
            collapsibleSection("add", "Add", lists.adds) { copy in
                row(copy.track.title, detail: copy.destination, symbol: "plus.circle", color: .green)
            }
            collapsibleSection("adopt", "Already on the Card (Recorded, Not Copied)", lists.adoptions) { adoption in
                row(adoption.track.title, detail: adoption.path, symbol: "checkmark.circle", color: .secondary)
            }
            if isSearching && lists.isEmpty {
                ContentUnavailableView.search(text: trimmedSearch)
            } else if plan.isEmpty {
                ContentUnavailableView("Already Up to Date", systemImage: "checkmark.circle",
                                       description: Text("Everything you selected is already on the card."))
            }
        }
        .listStyle(.inset)
    }

    /// Removal switches (always shown) and the songs to remove.
    @ViewBuilder
    private func removalSection(_ removals: [RemoveOperation]) -> some View {
        if !plan.removals.isEmpty {
            let expanded = isExpanded("remove", count: plan.removals.count)
            Section {
                Toggle("Remove the \(plan.removals.count.formatted()) songs you no longer sync",
                       isOn: Binding(get: { sync.options.applyRemovals },
                                     set: { sync.options.applyRemovals = $0 }))
                Toggle("Move them to a trash folder on the card instead of deleting them",
                       isOn: Binding(get: { sync.options.moveRemovalsToTrash },
                                     set: { sync.options.moveRemovalsToTrash = $0 }))
                    .disabled(!sync.options.applyRemovals)
                if assessment.needsLargeRemovalConfirmation {
                    Label("That's \(removalPercent)% of the songs on this card. You'll be asked to confirm.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                collapsibleRows(removals, expanded: expanded) { removal in
                    row(removal.entry.title, detail: removal.entry.path, symbol: "minus.circle", color: .red)
                }
            } header: {
                sectionHeader("Remove", shown: removals.count, total: plan.removals.count, expanded: expanded)
            } footer: {
                Text("Removals are off unless you turn them on. Songs not put there by Q2 Sync are never removed here.")
            }
        }
    }

    /// Music on the card that isn't in the Mac selection, each with a
    /// choice: leave, copy to Mac, move to the card's trash, or delete.
    @ViewBuilder
    private func cardOnlySection(_ items: [CardOnlyItem]) -> some View {
        if !plan.cardOnly.isEmpty {
            let expanded = isExpanded("cardOnly", count: plan.cardOnly.count)
            Section {
                HStack {
                    Text(isSearching ? "Set all \(items.count.formatted()) shown to:" : "Set all to:")
                    ForEach(CardOnlyAction.allCases) { action in
                        Button(action.title) {
                            var actions = sync.options.cardOnlyActions
                            for item in items { actions[item.path] = action }
                            sync.options.cardOnlyActions = actions
                        }
                        .controlSize(.small)
                    }
                }
                .disabled(items.isEmpty)
                collapsibleRows(items, expanded: expanded) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: item.origin == .unmanaged ? "sdcard" : "music.note.house")
                            .foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayName).lineLimit(1)
                            Text(cardOnlyDetail(item))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        // A pop-up menu bound to this file's choice.
                        Picker("Action", selection: Binding(
                            get: { sync.options.cardOnlyActions[item.path] ?? .leave },
                            set: { sync.options.cardOnlyActions[item.path] = $0 })) {
                            ForEach(CardOnlyAction.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } header: {
                sectionHeader("On the Card Only", shown: items.count, total: plan.cardOnly.count, expanded: expanded)
            } footer: {
                Text("Music on the card that isn't part of what you sync. Nothing here changes unless you choose. “Copy to Mac” puts a copy in Downloads › Q2 Recovered for you to add to Music yourself; it never touches your Music library.")
            }
        }
    }

    // MARK: Collapsing

    /// Open/closed state for a section. While filtering, every section is
    /// open so matches are never hidden.
    private func isExpanded(_ id: String, count: Int, alwaysOpen: Bool = false) -> Binding<Bool> {
        Binding(
            get: { isSearching || (expansion[id] ?? (alwaysOpen || count <= Self.collapseThreshold)) },
            set: { expansion[id] = $0 })
    }

    /// A section header that opens and closes its section, e.g. "Add (9,214)"
    /// or, while filtering, "Add (12 of 9,214)".
    private func sectionHeader(_ title: String, shown: Int, total: Int, expanded: Binding<Bool>) -> some View {
        let count = shown == total ? total.formatted() : "\(shown.formatted()) of \(total.formatted())"
        return Button {
            withAnimation(.snappy) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                Text("\(title) (\(count))")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSearching)
        .help(expanded.wrappedValue ? "Hide this list" : "Show this list")
    }

    /// The item rows when open; a "Show all" link when closed.
    @ViewBuilder
    private func collapsibleRows<Item: Identifiable, Row: View>(_ items: [Item], expanded: Binding<Bool>,
                                                                 @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        if expanded.wrappedValue {
            ForEach(items) { row($0) }
        } else if !items.isEmpty {
            Button("Show all \(items.count.formatted())") {
                withAnimation(.snappy) { expanded.wrappedValue = true }
            }
            .buttonStyle(.link)
        }
    }

    /// A collapsible list section, shown only when it has items.
    @ViewBuilder
    private func collapsibleSection<Item: Identifiable, Row: View>(_ id: String, _ title: String, _ items: [Item],
                                                                    alwaysOpen: Bool = false,
                                                                    @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        if !items.isEmpty {
            let expanded = isExpanded(id, count: items.count, alwaysOpen: alwaysOpen)
            Section {
                collapsibleRows(items, expanded: expanded, row: row)
            } header: {
                sectionHeader(title, shown: items.count, total: items.count, expanded: expanded)
            }
        }
    }

    /// e.g. "Old Rips/song.mp3 · 4.2 MB · already in your library".
    private func cardOnlyDetail(_ item: CardOnlyItem) -> String {
        var parts = [item.path, Int64(item.size).formatted(ByteCountFormatStyle(style: .file))]
        if case .removedFromLibrary = item.origin { parts.append("synced earlier, no longer in your library") }
        if item.isInLibrary { parts.append("already in your library: won't be copied") }
        return parts.joined(separator: " · ")
    }

    /// Playlist files to write and remove, with any limits or renames.
    @ViewBuilder
    private func playlistSection(writes: [PlannedPlaylist], removals: [PlaylistRemoval]) -> some View {
        let playlists = plan.playlistPlan
        if !playlists.writes.isEmpty || !playlists.removals.isEmpty || !playlists.overLimit.isEmpty {
            Section {
                ForEach(writes) { planned in
                    row(planned.playlist.name,
                        detail: planned.nameWasChanged ? "Saved as “\(planned.nameOnDevice)” (shortened or renamed for the Q2)"
                                                       : planned.path,
                        symbol: "music.note.list", color: .pink)
                }
                ForEach(removals) { removal in
                    row((removal.path as NSString).lastPathComponent,
                        detail: "No longer selected: its file is removed from the card",
                        symbol: "minus.circle", color: .red)
                }
                if !playlists.overLimit.isEmpty {
                    Label("The Q2 holds up to \(preview.profile.maximumPlaylists) playlists. These \(playlists.overLimit.count) won't be written: "
                          + playlists.overLimit.map(\.name).joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if playlists.otherPlaylistFiles > 0 {
                    Label("The playlist folder also has \(playlists.otherPlaylistFiles) playlist files Q2 Sync didn't write. The Q2 imports those too, and they're left untouched.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Playlists (\(playlists.writes.count))")
            } footer: {
                Text("On the Q2, choose Library → Playlists → Import to bring these in. Removing a playlist's file doesn't remove a playlist you already imported; delete that on the Q2. Songs that aren't on the card (for example, cloud-only songs) are left out of playlists.")
            }
        }
    }

    private func row(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let log = preview.dryRunLogURL {
                Button("Show Preview Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
            }
            Spacer()
            Button(preview.isFirstSync ? "Close" : "Cancel") { sync.close() }
                .keyboardShortcut(.cancelAction)
            if !preview.isFirstSync {
                Button("Sync") { continueApplying() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!assessment.canApply || (plan.isEmpty && !hasCardOnlyWork))
            }
        }
    }
}

// MARK: - Progress

/// Progress bar, current item and Cancel.
struct SyncProgressView: View {

    let sync: SyncCoordinator

    var body: some View {
        let progress = sync.progress
        VStack(alignment: .leading, spacing: 12) {
            Text("Syncing…").font(.title2.bold())
            ProgressView(value: progress.fractionComplete)
            Text(progress.currentItem.isEmpty ? "Starting…" : progress.currentItem)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail(progress))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack {
                Text("Don't disconnect the Q2 while syncing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { sync.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    /// e.g. "1.2 GB of 8.4 GB · 120 of 431 items".
    private func detail(_ progress: SyncProgress) -> String {
        let style = ByteCountFormatStyle(style: .file)
        var parts: [String] = []
        if progress.totalBytes > 0 {
            parts.append("\(Int64(progress.bytesCopied).formatted(style)) of \(Int64(progress.totalBytes).formatted(style))")
        }
        if progress.totalOperations > 0 {
            parts.append("\(progress.completedOperations.formatted()) of \(progress.totalOperations.formatted()) items")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Result

/// The outcome, with the "update your Q2's library" reminder.
struct SyncResultView: View {

    let report: SyncReport
    let profile: DeviceProfile
    let sync: SyncCoordinator
    let devices: DeviceMonitor

    /// Errors listed on screen; the rest are in the log.
    private static let maxErrorsShown = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if report.succeeded {
                Label("Sync Complete", systemImage: "checkmark.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
            } else if report.wasCancelled {
                Label("Sync Cancelled", systemImage: "stop.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.orange)
            } else {
                Label("Sync Finished with Problems", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.orange)
            }

            Text(summary)

            if let reason = report.abortReason {
                Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !report.errors.isEmpty {
                // Capped and lazy: a failed sync of thousands of songs can
                // produce thousands of errors; the log has all of them.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(report.errors.prefix(Self.maxErrorsShown).enumerated()), id: \.offset) {
                            Text($0.element).font(.caption)
                        }
                        if report.errors.count > Self.maxErrorsShown {
                            Text("and \((report.errors.count - Self.maxErrorsShown).formatted()) more — see the log")
                                .font(.caption.italic())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            if report.succeeded && !sync.didEject {
                Text("Eject the card now? You can also keep it connected to sync again.")
                    .fontWeight(.medium)
            } else if report.succeeded {
                Text("The card has been ejected. Next, on your Q2:")
                    .fontWeight(.medium)
                ForEach(Array(profile.libraryUpdateSteps.enumerated()), id: \.offset) { index, step in
                    Label(step, systemImage: "\(index + 1).circle")
                }
            } else {
                Text("The card is still connected. Fix the problems above and sync again; songs already copied won't be copied twice.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let log = report.logURL {
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                }
                Spacer()
                if report.succeeded && !sync.didEject {
                    Button("Not Now") { sync.close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Eject") { Task { await sync.ejectAfterSync(devices: devices) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(sync.isEjecting)
                } else {
                    Button("Done") { sync.close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    /// e.g. "Added 12, updated 1, removed 0 · 84.3 MB in 0:42".
    private var summary: String {
        var parts = ["Added \(report.added)", "updated \(report.updated)"]
        if report.moved > 0 { parts.append("renamed \(report.moved)") }
        if report.removed + report.trashed > 0 { parts.append("removed \(report.removed + report.trashed)") }
        if report.adopted > 0 { parts.append("recorded \(report.adopted) already on the card") }
        if report.copiedBack > 0 { parts.append("\(report.copiedBack) copied to your Mac") }
        if report.cardOnlyTrashed + report.cardOnlyRemoved > 0 {
            parts.append("\(report.cardOnlyTrashed + report.cardOnlyRemoved) card-only files removed")
        }
        if report.playlistsWritten > 0 { parts.append("\(report.playlistsWritten) playlists written") }
        if report.playlistsRemoved > 0 { parts.append("\(report.playlistsRemoved) playlists removed") }
        let copied = report.bytesCopied == 0
            ? "nothing copied"
            : "\(Int64(report.bytesCopied).formatted(ByteCountFormatStyle(style: .file))) copied"
        return parts.joined(separator: ", ") + " · \(copied)"
    }
}
