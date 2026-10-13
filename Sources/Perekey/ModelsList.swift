// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore
import SwiftUI

/// The speech models of the catalog: state, download, delete, and the disk
/// they take. The downloads belong to `VoiceModelsController`, so closing the
/// window leaves them running.
struct ModelsList: View {
    let controller: VoiceModelsController

    private var recognizers: [VoiceModelStatus] {
        controller.statuses.filter { $0.entry.engine.recognizes }
    }

    private var downloadsForbidden: Bool { controller.settings.managed.voiceModelDownloadsDisabled }

    var body: some View {
        PKGroup(header: voiceText("Models")) {
            if downloadsForbidden {
                PKNote(voiceText("Your administrator turned off model downloads. Perekey reads models from the folder /Library/Application Support/Perekey/VoiceModels."))
                PKDivider()
            } else if !controller.settings.settings.isEnabled {
                PKNote(voiceText("Turn on voice input to download models."))
                PKDivider()
            }
            ForEach(Array(recognizers.enumerated()), id: \.element.id) { index, status in
                if index > 0 { PKDivider() }
                ModelRow(status: status, controller: controller, error: controller.errors[status.id])
            }
            PKDivider()
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                diskText
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { controller.revealFolder() } label: { voiceText("Show folder") }
                    .buttonStyle(.pkSmall)
                Button(action: confirmDeleteAll) { voiceText("Delete all") }
                    .buttonStyle(.pkSmall)
                    .disabled(downloadsForbidden || !hasAnythingOnDisk)
            }
            if !controller.keptByDeleteAll.isEmpty {
                Text(verbatim: voiceString("In use, so kept: \(keptTitles)"))
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkWarn)
            }
        }
        .padding(.horizontal, PK.Space.lg)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }

    private var keptTitles: String {
        controller.keptByDeleteAll.compactMap { ModelCatalog.entry(id: $0)?.title }.joined(separator: ", ")
    }

    private var hasAnythingOnDisk: Bool {
        (controller.usage?.total ?? 0) > 0
    }

    private var diskText: Text {
        guard let usage = controller.usage else { return voiceText("Disk use: counting…") }
        return Text(verbatim: voiceString("Disk use: \(ModelSize.text(usage.total)) (with cache)"))
    }

    private func confirmDeleteAll() {
        let alert = NSAlert()
        alert.messageText = voiceString("Delete all speech models?")
        alert.informativeText = voiceString("Perekey will delete the downloaded models and the cache that speeds up loading them. You can download a model again later. A model in use stays.")
        alert.addButton(withTitle: voiceString("Delete all"))
        alert.addButton(withTitle: voiceString("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { controller.deleteAll() }
    }
}

enum ModelSize {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct ModelRow: View {
    let status: VoiceModelStatus
    let controller: VoiceModelsController
    let error: VoiceModelFailure?

    private var title: String { status.entry.title }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title).font(PK.Font.body).foregroundStyle(Color.pkInk)
                HStack(spacing: 6) {
                    PKTag(text: voiceText("offline"))
                    if status.id == VoiceSettings.defaultModel { PKTag(text: voiceText("recommended")) }
                    if status.isInUse { PKTag(text: voiceText("in use")) }
                    if status.isManaged { PKTag(text: voiceText("from your administrator")) }
                }
                .accessibilityElement(children: .combine)
                stateLine
                if let failure = status.failure ?? error {
                    Text(verbatim: ModelFailureText.text(failure))
                        .font(PK.Font.caption)
                        .foregroundStyle(Color.pkRose)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let size = sizeText {
                Text(verbatim: size).font(PK.Font.caption).foregroundStyle(Color.pkInk2)
            }
            buttons
        }
        .padding(.horizontal, PK.Space.lg)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }

    /// The size the model brings (or takes, when it is on disk).
    private var sizeText: String? {
        switch status.state {
        case .absent, .partial, .damaged: ModelSize.text(status.size)
        case .downloading, .waitingForNetwork: nil
        case .ready: ModelSize.text(status.entry.totalSize)
        }
    }

    @ViewBuilder private var stateLine: some View {
        switch status.state {
        case .absent:
            EmptyView()
        case let .partial(received):
            line(voiceText("Paused at \(percent(received))"))
        case let .downloading(received):
            progressLine(received: received, waiting: false)
        case let .waitingForNetwork(received):
            progressLine(received: received, waiting: true)
        case .ready:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
                voiceText("Ready")
            }
            .font(PK.Font.caption)
            .foregroundStyle(Color.pkOK)
        case .damaged:
            line(voiceText("Files are damaged or missing"), color: .pkWarn)
        }
    }

    private func line(_ text: Text, color: Color = .pkInk2) -> some View {
        text.font(PK.Font.caption).foregroundStyle(color)
    }

    private func progressLine(received: Int64, waiting: Bool) -> some View {
        let fraction = status.progress ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            ProgressBar(fraction: fraction)
                .frame(width: 220, height: 5)
            line(waiting
                 ? voiceText("Waiting for the network… \(percent(received))")
                 : Text(verbatim: voiceString("\(ModelSize.text(received)) of \(ModelSize.text(status.size))")))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceText("Downloading \(title)"))
        .accessibilityValue(waiting
                            ? voiceText("Waiting for the network, \(percent(received))")
                            : Text(verbatim: percent(received)))
    }

    private func percent(_ received: Int64) -> String {
        let fraction = status.entry.totalSize > 0 ? min(1, Double(received) / Double(status.entry.totalSize)) : 0
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        let forbidden = controller.settings.managed.voiceModelDownloadsDisabled
        switch status.state {
        case .absent:
            if !forbidden {
                action(voiceText("Download"), label: voiceString("Download \(title)"), primary: true,
                       enabled: controller.canDownload) { controller.download(status.id) }
            }
        case .partial:
            HStack(spacing: 6) {
                if !forbidden {
                    action(voiceText("Resume"), label: voiceString("Resume downloading \(title)"), primary: true,
                           enabled: controller.canDownload) { controller.download(status.id) }
                }
                deleteButton
            }
        case .downloading, .waitingForNetwork:
            action(voiceText("Cancel"), label: voiceString("Cancel downloading \(title)")) { controller.cancel(status.id) }
        case .ready:
            deleteButton
        case .damaged:
            HStack(spacing: 6) {
                if !forbidden {
                    action(voiceText("Repair"), label: voiceString("Repair \(title)"), primary: true,
                           enabled: controller.canDownload && !status.isInUse) { controller.download(status.id) }
                }
                deleteButton
            }
        }
    }

    @ViewBuilder private var deleteButton: some View {
        if !status.isManaged {
            Button { controller.delete(status.id) } label: { voiceText("Delete") }
                .buttonStyle(.pkSmall)
                .disabled(status.isInUse)
                .help(status.isInUse ? voiceText("The model is in use. Delete it when dictation is done.") : voiceText("Delete the model files"))
                .accessibilityLabel(Text(verbatim: voiceString("Delete \(title)")))
        }
    }

    private func action(_ text: Text, label: String, primary: Bool = false, enabled: Bool = true,
                        _ run: @escaping () -> Void) -> some View
    {
        Button(action: run) { text }
            .buttonStyle(PKButtonStyle(kind: primary ? .primary : .secondary, small: true))
            .disabled(!enabled)
            .accessibilityLabel(Text(verbatim: label))
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.pkWashDeep)
                Capsule().fill(Color.pkIndigo).frame(width: max(5, proxy.size.width * fraction))
            }
        }
    }
}

/// What went wrong, in words a person can act on.
enum ModelFailureText {
    static func text(_ failure: VoiceModelFailure) -> String {
        switch failure {
        case .voiceDisabled: voiceString("Voice input is turned off by your administrator.")
        case .downloadsDisabled: voiceString("Your administrator turned off model downloads.")
        case .networkBlocked: voiceString("Turn on voice input to download models.")
        case .unknownModel: voiceString("Perekey does not know this model.")
        case .notReady: voiceString("The model is not downloaded yet.")
        case .inUse: voiceString("The model is in use.")
        case .requiredBy: voiceString("Another model needs these files.")
        case let .http(status, host): voiceString("The server \(host) answered with error \(String(status)). Try again later.")
        case .untrustedRedirect: voiceString("The server sent the download to an address Perekey does not trust. Nothing was downloaded.")
        case .checksumMismatch: voiceString("The downloaded file does not match its checksum. Download the model again.")
        case .network: voiceString("The network failed. Download again to continue where it stopped.")
        case .offline: voiceString("No network connection. Download again when it is back.")
        case let .notEnoughSpace(needed, available):
            voiceString("Not enough disk space: the model needs \(ModelSize.text(needed)), \(ModelSize.text(available)) is free.")
        case .disk: voiceString("Perekey cannot write to the disk. Check the free space and the permissions of the folder.")
        }
    }
}
#endif
