//
//  LibrarySource.swift
//  Q2-Sync › Core › Library
//
//  PURPOSE
//  Defines the one question the rest of the app may ask the Mac's music
//  library: "give me a read-only snapshot of yourself".
//
//  HOW IT FITS
//  There are two implementations:
//    • `ITunesLibrarySource`  – the real Apple Music library (via ITLibrary)
//    • `FixtureLibrarySource` – a fake library for tests and SwiftUI previews
//
//  Code that needs library data depends on the `LibrarySource` *protocol*,
//  not a concrete type. That lets tests swap in fixtures so they never touch
//  the real library, which is one of this project's safety rules.
//
//  Notice what the protocol does NOT have: no save, no edit, no delete.
//  There is simply no way to ask a `LibrarySource` to change anything.
//

import Foundation

/// Something that can produce a read-only `LibrarySnapshot`.
///
/// `Sendable` means instances can be safely shared across threads, which
/// Swift's strict concurrency checking requires for anything we use from
/// background tasks.
protocol LibrarySource: Sendable {

    /// Reads the library and returns an immutable snapshot of it.
    ///
    /// `async` means callers must `await` this function: it may take a few
    /// seconds for a large library, and awaiting lets the UI stay responsive
    /// while it runs.
    ///
    /// - Returns: A snapshot of all music tracks and playlists.
    /// - Throws: `LibraryError` if the library can't be read.
    /// - Side effects: None. Reading only.
    func loadSnapshot() async throws -> LibrarySnapshot
}

/// Problems that can happen while reading the library.
///
/// `LocalizedError` lets SwiftUI show `errorDescription` directly in alerts.
enum LibraryError: LocalizedError, Equatable {

    /// ITLibrary refused to open the library. Usually means the app was not
    /// granted access in System Settings › Privacy & Security › Media &
    /// Apple Music, or the sandbox entitlement is missing.
    case accessDenied(underlying: String)

    /// A fixture file couldn't be read or decoded (tests/previews only).
    case fixtureUnreadable(underlying: String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let underlying):
            return "Q2 Sync couldn't open your Apple Music library. "
                + "Check System Settings › Privacy & Security › Media & Apple Music. "
                + "(\(underlying))"
        case .fixtureUnreadable(let underlying):
            return "The test library file couldn't be read. (\(underlying))"
        }
    }
}
