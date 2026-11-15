//
//  NewDeviceSheet.swift
//  Q2-Sync › Views
//
//  PURPOSE
//  The "Is this your Shanling Q2?" sheet shown the first time an eligible
//  drive connects. The user confirms it's their Q2, picks its firmware,
//  and then grants write access in an Open panel.
//
//  HOW IT FITS
//  Presented by `RootView` whenever `DeviceMonitor.pendingVolume` is set.
//
//  WHY ASK AT ALL
//  A different card or USB stick must never be mistaken for the Q2. Only a
//  drive the user explicitly confirms (remembered by its UUID) is synced.
//

import SwiftUI

/// Asks whether a newly connected drive is the user's Q2.
struct NewDeviceSheet: View {

    let volume: VolumeInfo
    let devices: DeviceMonitor

    /// The firmware the user selects. Q2 Pod is the default.
    @State private var firmware: FirmwareKind = .q2Pod

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "ipod")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Is this your Shanling Q2?")
                        .font(.title2.bold())
                    Text(volumeDescription)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Q2 Sync will only ever write to a card you confirm here. It remembers this card by its unique ID, so other drives are never mistaken for it.")
                .fixedSize(horizontal: false, vertical: true)

            Picker("Firmware on this Q2:", selection: $firmware) {
                ForEach(FirmwareKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)

            Label("Next, macOS will show this card in an Open window. Click Grant Access to let Q2 Sync change files on this card only.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Not My Q2") { devices.markNotQ2(volume) }
                    .help("Never ask about this drive again")
                Spacer()
                Button("Later") { devices.postpone(volume) }
                    .keyboardShortcut(.cancelAction)
                Button("Continue…") { devices.confirm(volume, firmware: firmware) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    /// e.g. "“Q2CARD” · 256 GB · ExFAT".
    private var volumeDescription: String {
        let size = volume.totalCapacity.map { $0.formatted(ByteCountFormatStyle(style: .file)) }
        return ["“\(volume.name)”", size, volume.formatDescription]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

#Preview {
    NewDeviceSheet(
        volume: VolumeInfo(url: URL(filePath: "/Volumes/Q2CARD"), uuid: "X", name: "Q2CARD",
                           isRemovable: true, isEjectable: true, isInternal: false,
                           isRootFileSystem: false, formatDescription: "ExFAT",
                           totalCapacity: 256_000_000_000, availableCapacity: 255_000_000_000),
        devices: DeviceMonitor())
}
