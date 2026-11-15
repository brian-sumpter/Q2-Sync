//
//  LibraryCategoryView.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  Browses one library category (Artists, Albums, Genres or Playlists):
//  a list of groups on the left, the selected group's tracks on the right.
//  A read-only browser; choosing what to sync happens in `DeviceMusicView`.
//
//  HOW IT FITS
//  Shown by `RootView` when a Library row is selected in the sidebar.
//
//  SAFETY
//  The library is never read automatically; the user clicks Read Library.
//

import SwiftUI

/// The sidebar's library categories.
///
/// `CaseIterable` gives `allCases` to build the sidebar, and
/// `Identifiable` lets SwiftUI tell rows apart.
enum BrowseCategory: String, CaseIterable, Identifiable, Hashable {
    case artists = "Artists"
    case albums = "Albums"
    case genres = "Genres"
    case playlists = "Playlists"

    var id: String { rawValue }

    /// SF Symbol for the sidebar row (the same icons Music uses).
    var symbolName: String {
        switch self {
        case .artists:   return "music.microphone"
        case .albums:    return "square.stack"
        case .genres:    return "guitars"
        case .playlists: return "music.note.list"
        }
    }

    /// The groups for this category from a snapshot.
    func groups(in snapshot: LibrarySnapshot) -> [TrackGroup] {
        switch self {
        case .artists:   return snapshot.artistGroups
        case .albums:    return snapshot.albumGroups
        case .genres:    return snapshot.genreGroups
        case .playlists: return snapshot.playlistGroups
        }
    }
}

/// A two-pane browser for one category.
struct LibraryCategoryView: View {

    let library: LibraryModel
    let category: BrowseCategory

    /// The selected group's ID.
    @State private var groupID: String?

    var body: some View {
        Group {
            if let snapshot = library.snapshot {
                let groups = category.groups(in: snapshot)
                // `HSplitView` gives a user-resizable divider, as in Music.
                HSplitView {
                    List(groups, selection: $groupID) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                            if let subtitle = group.subtitle {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .badge(group.trackIDs.count)
                        .tag(group.id)
                    }
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)

                    if let group = groups.first(where: { $0.id == groupID }) {
                        TrackTableView(tracks: snapshot.tracks(for: group.trackIDs))
                            .frame(minWidth: 400)
                    } else {
                        ContentUnavailableView("Select an Item", systemImage: "music.note",
                                               description: Text("Choose one on the left to see its songs."))
                            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Library Not Read Yet", systemImage: "music.note.house")
                } description: {
                    Text("Click Read Library to load your Apple Music library. Q2 Sync only ever reads it. It never changes anything.")
                }
            }
        }
        .navigationTitle(category.rawValue)
        .onChange(of: category) { groupID = nil }
    }
}

// MARK: - Playlist groups

extension LibrarySnapshot {

    /// Playlists presented as `TrackGroup`s, so the browser can treat them
    /// like artists or albums. Folders are left out (they hold no tracks).
    var playlistGroups: [TrackGroup] {
        playlists
            .filter { $0.kind != .folder }
            .map { TrackGroup(id: "playlist:\($0.id)", title: $0.name,
                              subtitle: $0.kind == .smart ? "Smart Playlist" : nil,
                              trackIDs: $0.trackIDs) }
            .sorted { SortKey.compare($0.title, $1.title) }
    }
}
