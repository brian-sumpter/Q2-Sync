// swift-tools-version: 6.2
//
//  Package.swift
//  Q2-Sync
//
//  PURPOSE
//  This Swift Package exists only so the app's "engine" code can be unit
//  tested quickly from the command line (`swift test`) or from Xcode.
//
//  HOW IT FITS
//  The Xcode app target already compiles everything inside `Q2-Sync/`,
//  including `Q2-Sync/Core`. This package points at the *same* `Core`
//  folder (no copies), so:
//
//      Q2-Sync/Core/...   ← compiled into the app AND into this package
//      Tests/...          ← compiled only into the test target here
//
//  The Core folder must therefore never import SwiftUI or AppKit-only UI
//  code: it is the UI-free, testable heart of the app.
//

import PackageDescription

/// Compiler settings shared by the library and its tests.
///
/// They mirror the Xcode app target's "Approachable Concurrency" settings so
/// the Core code behaves the same way whether it's built by Xcode or by
/// `swift test`.
let sharedSwiftSettings: [SwiftSetting] = [
    // `nonisolated async` functions run on the caller's actor unless marked
    // `@concurrent`. This matches Xcode's SWIFT_APPROACHABLE_CONCURRENCY.
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "Q2SyncCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "Q2SyncCore", targets: ["Q2SyncCore"]),
    ],
    targets: [
        .target(
            name: "Q2SyncCore",
            path: "Q2-Sync/Core",
            swiftSettings: sharedSwiftSettings,
            linkerSettings: [
                // Apple's read-only framework for reading the Music library.
                .linkedFramework("iTunesLibrary"),
            ]
        ),
        .testTarget(
            name: "Q2SyncCoreTests",
            dependencies: ["Q2SyncCore"],
            path: "Tests/Q2SyncCoreTests",
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
