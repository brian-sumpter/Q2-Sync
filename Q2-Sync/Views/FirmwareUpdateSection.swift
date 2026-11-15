//
//  FirmwareUpdateSection.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  The "Firmware Updates" part of a Q2's Settings tab.
//    • Q2 Pod: an optional check of GitHub for new releases, your installed
//      version (typed in, as the card doesn't record it), the latest
//      release's notes, a link, and Dismiss.
//    • Stock: a link to Shanling's download page (not checked
//      automatically, as it isn't kept up to date).
//  Q2 Sync never downloads or installs firmware.
//
//  HOW IT FITS
//  Shown inside `DeviceSettingsView`'s Form. Data from `FirmwareModel`;
//  per-device values saved through `DeviceMonitor`.
//

import SwiftUI

/// Firmware update settings and status for one Q2.
struct FirmwareUpdateSection: View {

    let connected: ConnectedDevice
    let devices: DeviceMonitor
    let firmware: FirmwareModel

    /// Whether checking is on (saved in UserDefaults).
    @AppStorage(FirmwareModel.enabledKey) private var checkEnabled = false

    /// The version text being edited; saved when you press Return or leave the field.
    @State private var versionText = ""

    var body: some View {
        Section {
            if connected.device.firmware == .q2Pod {
                q2PodContent
            } else {
                stockContent
            }
        } header: {
            Text("Firmware Updates")
        } footer: {
            Text("Q2 Sync only tells you about new firmware. It never downloads or installs it; you update on the Q2 itself.")
        }
        .onAppear { versionText = connected.device.installedFirmwareVersion ?? "" }
    }

    // MARK: Q2 Pod

    @ViewBuilder
    private var q2PodContent: some View {
        Toggle("Check GitHub for new Q2 Pod releases", isOn: $checkEnabled)
            .onChange(of: checkEnabled) { _, on in
                if on { Task { await firmware.checkNow() } }
            }

        TextField("Installed version", text: $versionText, prompt: Text("e.g. 1.8.5 (optional)"))
            .onSubmit { devices.setInstalledFirmwareVersion(versionText) }
            .onChange(of: versionText) { _, text in
                // Save as soon as it parses, so the status updates live.
                if text.isEmpty || FirmwareVersion(text) != nil { devices.setInstalledFirmwareVersion(text) }
            }

        if checkEnabled {
            HStack {
                statusLabel
                Spacer()
                if firmware.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check Now") { Task { await firmware.checkNow() } }
                }
            }
            if let error = firmware.errorMessage {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            if let latest = firmware.latest {
                releaseDetails(latest)
            }
        }
    }

    /// One line summarising the status.
    @ViewBuilder
    private var statusLabel: some View {
        let latestTag = firmware.latest?.tag ?? ""
        switch firmware.status(for: connected.device) {
        case .upToDate?:
            Label("You have the latest Q2 Pod (\(latestTag)).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .updateAvailable?:
            Label("Q2 Pod \(latestTag) is available.", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case .newRelease?:
            Label("The latest Q2 Pod release is \(latestTag).", systemImage: "sparkles")
                .foregroundStyle(.blue)
        case .dismissed?:
            Label("Latest Q2 Pod: \(latestTag) (dismissed).", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case nil:
            Text("Not checked yet.").foregroundStyle(.secondary)
        }
    }

    /// The release's notes (rendered from Markdown), link and Dismiss.
    @ViewBuilder
    private func releaseDetails(_ release: FirmwareRelease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Q2 Pod \(release.tag)").font(.headline)
                if let date = release.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(Self.markdown(release.notes))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            HStack {
                Link("View Release on GitHub", destination: release.pageURL)
                Spacer()
                if firmware.status(for: connected.device)?.shouldNotify == true {
                    Button("Dismiss") { devices.dismissFirmwareRelease(release.tag) }
                }
            }
        }
    }

    // MARK: Stock

    @ViewBuilder
    private var stockContent: some View {
        Text("Shanling's stock firmware isn't checked automatically: its download page isn't kept up to date. On the Q2, System Setting → System Update → Network update checks Shanling's servers.")
            .font(.callout)
        Link("Open Shanling's Q2 Download Page", destination: FirmwareUpdateChecker.stockDownloadPage)
    }

    /// Release notes as styled text; falls back to plain text.
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
