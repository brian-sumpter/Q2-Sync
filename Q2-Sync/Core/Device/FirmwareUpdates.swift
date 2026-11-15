//
//  FirmwareUpdates.swift
//  Q2-Sync › Core › Device
//
//  PURPOSE
//  Optional check for new Q2 Pod firmware releases on GitHub. It only
//  READS release information (version, notes, link) and tells you about
//  it. It never downloads or installs firmware: you update the Q2 yourself
//  (System settings → System Update), as Q2 Pod's guide describes.
//
//  WHAT WE KNOW (checked 2026-11-15)
//  • Releases: https://api.github.com/repos/DiamondBond/q2-pod/releases/latest
//    Tags look like "1.8.5"; release notes sometimes mention an internal
//    number like "V1850".
//  • The installed version is stored on the Q2 itself, NOT on the card, so
//    Q2 Sync can't read it. You can type it in (the Q2 shows it under
//    About as "CFW. Version"); otherwise Q2 Sync tells you about releases
//    newer than the last one you dismissed.
//  • Stock firmware: Shanling's download page still lists V1.32 while
//    V1.36 exists, so it isn't a reliable source and isn't checked. The
//    Q2's own System Update → Network update checks Shanling's servers.
//

import Foundation

/// One firmware release from GitHub.
struct FirmwareRelease: Codable, Sendable, Equatable {
    /// The release tag, e.g. "1.8.5".
    let tag: String
    /// The release title.
    let name: String
    /// Release notes (Markdown).
    let notes: String
    /// The release's web page.
    let pageURL: URL
    /// When it was published.
    let publishedAt: Date?

    /// The fields we read from GitHub's JSON. `CodingKeys` maps GitHub's
    /// snake_case names to our Swift names.
    private struct GitHubJSON: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let published_at: Date?
        let draft: Bool?
        let prerelease: Bool?
    }

    /// Parses GitHub's "latest release" JSON.
    ///
    /// - Parameter data: The API response body.
    /// - Returns: The release.
    /// - Throws: `FirmwareCheckError.unexpectedResponse` for drafts,
    ///   pre-releases or unreadable JSON.
    static func parseGitHub(_ data: Data) throws -> FirmwareRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let json = try? decoder.decode(GitHubJSON.self, from: data),
              json.draft != true, json.prerelease != true else {
            throw FirmwareCheckError.unexpectedResponse
        }
        return FirmwareRelease(tag: json.tag_name, name: json.name ?? json.tag_name, notes: json.body ?? "",
                               pageURL: json.html_url, publishedAt: json.published_at)
    }
}

/// Problems checking for firmware.
enum FirmwareCheckError: LocalizedError, Equatable {
    case unexpectedResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse: return "GitHub's answer couldn't be read."
        case .httpStatus(let code): return "GitHub answered with an error (\(code)). Try again later."
        }
    }
}

/// A comparable firmware version such as 1.8.5.
struct FirmwareVersion: Comparable, Sendable, CustomStringConvertible {

    /// The numbers, e.g. [1, 8, 5]. Trailing zeros are removed so 1.8.5
    /// and 1.8.5.0 compare equal.
    let components: [Int]

    /// Parses what people and GitHub write:
    ///   "1.8.5", "v1.8.5", "V1.8.5", "Q2 Pod 1.8.5" → 1.8.5
    ///   "V1850", "1850" (the internal style) → 1.8.5.0 → 1.8.5
    /// Returns `nil` for text with no version in it.
    init?(_ text: String) {
        // Prefer a dotted number ("1.8.5"); otherwise take the longest run
        // of digits, so the "2" in "Q2" isn't mistaken for the version.
        let token: String
        if let dotted = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) {
            token = String(text[dotted])
        } else if let longest = text.split(whereSeparator: { !$0.isNumber }).max(by: { $0.count < $1.count }) {
            token = String(longest)
        } else {
            return nil
        }
        var numbers: [Int]
        if token.contains(".") {
            numbers = token.split(separator: ".").compactMap { Int($0) }
        } else if (3...4).contains(token.count) {
            // "1850" → 1, 8, 5, 0 (one digit per part, as in "V1850").
            numbers = token.compactMap { $0.wholeNumberValue }
        } else {
            numbers = [Int(token) ?? 0]
        }
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        guard !numbers.isEmpty else { return nil }
        components = numbers
    }

    static func < (a: FirmwareVersion, b: FirmwareVersion) -> Bool {
        for index in 0..<max(a.components.count, b.components.count) {
            let x = index < a.components.count ? a.components[index] : 0
            let y = index < b.components.count ? b.components[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    var description: String { components.map(String.init).joined(separator: ".") }
}

/// What the check found, compared with what you have.
enum FirmwareUpdateStatus: Equatable, Sendable {
    /// Your installed version is the latest (or newer).
    case upToDate
    /// A newer version than your installed one is available.
    case updateAvailable
    /// Your installed version is unknown, and this release is newer than
    /// the last one you dismissed (or you haven't dismissed any).
    case newRelease
    /// Nothing to tell you: you dismissed this release (or a newer one).
    case dismissed

    /// `true` if it's worth a notification / highlight.
    var shouldNotify: Bool { self == .updateAvailable || self == .newRelease }
}

/// Firmware update checking.
enum FirmwareUpdateChecker {

    /// GitHub's "latest release" endpoint for Q2 Pod.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/DiamondBond/q2-pod/releases/latest")!

    /// Shanling's download page for the Q2's stock firmware.
    static let stockDownloadPage = URL(string: "https://en.shanling.com/download/150")!

    /// Fetches the latest Q2 Pod release (read-only HTTPS request).
    ///
    /// - Parameter session: The URL session (tests could inject one).
    /// - Returns: The latest release.
    /// - Throws: Network or parsing errors.
    /// - Side effects: One request to api.github.com. No personal details
    ///   are sent; the User-Agent is just "Q2-Sync".
    static func fetchLatest(session: URLSession = .shared) async throws -> FirmwareRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Q2-Sync", forHTTPHeaderField: "User-Agent") // GitHub requires one.
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FirmwareCheckError.httpStatus(http.statusCode)
        }
        return try FirmwareRelease.parseGitHub(data)
    }

    /// Compares a release with what the user has.
    ///
    /// - Parameters:
    ///   - latest: The latest release.
    ///   - installed: The version the user typed in, if any.
    ///   - dismissedTag: The release the user last dismissed, if any.
    /// - Returns: The status.
    static func status(latest: FirmwareRelease, installed: String?, dismissedTag: String?) -> FirmwareUpdateStatus {
        guard let latestVersion = FirmwareVersion(latest.tag) else { return .dismissed }
        // Dismissed this release, or a newer one: stay quiet.
        if let dismissedTag, let dismissed = FirmwareVersion(dismissedTag), dismissed >= latestVersion {
            if let installed = installed.flatMap(FirmwareVersion.init), installed >= latestVersion {
                return .upToDate
            }
            return .dismissed
        }
        if let installed = installed.flatMap(FirmwareVersion.init) {
            return latestVersion > installed ? .updateAvailable : .upToDate
        }
        return .newRelease
    }
}
