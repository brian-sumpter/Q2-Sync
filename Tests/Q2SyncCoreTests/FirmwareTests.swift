//
//  FirmwareTests.swift
//  Q2-Sync › Tests
//
//  PURPOSE
//  Tests for parsing GitHub release JSON, comparing firmware versions, and
//  deciding when to tell the user about a release. No network access.
//

import Foundation
import Testing
@testable import Q2SyncCore

@Suite("Firmware updates")
struct FirmwareTests {

    /// A trimmed copy of GitHub's real "latest release" answer for 1.8.5.
    let json = """
    {"tag_name":"1.8.5","name":"1.8.5","draft":false,"prerelease":false,
     "published_at":"2026-11-15T16:58:44Z",
     "html_url":"https://github.com/DiamondBond/q2-pod/releases/tag/1.8.5",
     "body":"**1.8.5**\\n- Cover Flow: picking a song turns the cover over.\\n\\nSHA-256:\\n- update.tar (V1850): `90af`",
     "assets":[{"name":"update.tar","size":53985280}]}
    """

    func release(_ tag: String) -> FirmwareRelease {
        FirmwareRelease(tag: tag, name: tag, notes: "", pageURL: URL(string: "https://example.com")!, publishedAt: nil)
    }

    @Test("Parses GitHub's latest-release JSON")
    func parse() throws {
        let release = try FirmwareRelease.parseGitHub(Data(json.utf8))
        #expect(release.tag == "1.8.5")
        #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/1.8.5"))
        #expect(release.notes.contains("Cover Flow"))
        #expect(release.publishedAt != nil)
    }

    @Test("Drafts, pre-releases and junk are rejected")
    func rejects() {
        let pre = json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true")
        #expect(throws: FirmwareCheckError.self) { try FirmwareRelease.parseGitHub(Data(pre.utf8)) }
        #expect(throws: FirmwareCheckError.self) { try FirmwareRelease.parseGitHub(Data("nope".utf8)) }
    }

    @Test("Versions parse from the ways people write them")
    func parsing() {
        #expect(FirmwareVersion("1.8.5")?.description == "1.8.5")
        #expect(FirmwareVersion("v1.8.5")?.description == "1.8.5")
        #expect(FirmwareVersion("Q2 Pod 1.8.5")?.description == "1.8.5")
        #expect(FirmwareVersion("V1850")?.description == "1.8.5")
        #expect(FirmwareVersion("1.10.0")?.description == "1.10")
        #expect(FirmwareVersion("no version") == nil)
    }

    @Test("Versions compare numerically, not alphabetically")
    func comparing() {
        #expect(FirmwareVersion("1.8.5")! < FirmwareVersion("1.10")!)
        #expect(FirmwareVersion("1.8.5")! == FirmwareVersion("V1850")!)
        #expect(!(FirmwareVersion("1.9")! < FirmwareVersion("1.8.9")!))
    }

    @Test("Status with a known installed version")
    func withInstalled() {
        #expect(FirmwareUpdateChecker.status(latest: release("1.8.5"), installed: "1.8.4", dismissedTag: nil) == .updateAvailable)
        #expect(FirmwareUpdateChecker.status(latest: release("1.8.5"), installed: "V1850", dismissedTag: nil) == .upToDate)
        #expect(FirmwareUpdateChecker.status(latest: release("1.8.5"), installed: "1.9", dismissedTag: nil) == .upToDate)
    }

    @Test("Status without an installed version uses the last dismissed release")
    func withoutInstalled() {
        #expect(FirmwareUpdateChecker.status(latest: release("1.8.5"), installed: nil, dismissedTag: nil) == .newRelease)
        #expect(FirmwareUpdateChecker.status(latest: release("1.8.5"), installed: nil, dismissedTag: "1.8.5") == .dismissed)
        #expect(FirmwareUpdateChecker.status(latest: release("1.8.6"), installed: nil, dismissedTag: "1.8.5") == .newRelease)
        #expect(FirmwareUpdateChecker.status(latest: release("1.8.5"), installed: "1.8.4", dismissedTag: "1.8.5") == .dismissed)
    }
}
