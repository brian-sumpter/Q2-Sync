//
//  FirstLaunchNoticeView.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  A one-time notice shown the first time Q2 Sync opens. It explains that
//  the app never writes to your Apple Music library or its media folder,
//  and reminds you that keeping your own backup (Time Machine or another)
//  is best practice anyway. A single "I Understand" button dismisses it
//  for good.
//
//  HOW IT FITS
//  Presented by `RootView` until acknowledged. The acknowledgement is
//  saved in UserDefaults under `acknowledgedKey`. Q2 Sync deliberately has
//  no backup feature: backups are your responsibility.
//

import SwiftUI

/// The one-time "read-only, keep a backup" notice.
struct FirstLaunchNoticeView: View {

    /// UserDefaults key recording that the notice was acknowledged.
    static let acknowledgedKey = "acknowledgedLibraryNotice"

    /// Writing `true` here (via the button) dismisses the notice forever.
    @AppStorage(acknowledgedKey) private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Before You Start")
                    .font(.title.bold())
            }

            point(symbol: "music.note.house",
                  title: "Your Apple Music library is never changed",
                  text: "Q2 Sync NEVER writes to your Apple Music library or its media folder in any way. It is entirely read-only toward them: it only reads your library and copies music from your Mac to your Q2's card.")

            point(symbol: "externaldrive.badge.timemachine",
                  title: "Keep a backup anyway",
                  text: "Backups are best practice regardless of which apps you use. Please make sure you have a backup of your Mac (with Time Machine or another method) before you continue.")

            HStack {
                Spacer()
                Button("I Understand") { acknowledged = true }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 520)
        // There's only one way out: the button.
        .interactiveDismissDisabled()
    }

    /// One icon + bold title + explanation.
    private func point(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    FirstLaunchNoticeView()
}
