// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore
import SwiftUI

/// «Модель»: the speech models of the catalog as a choice, with their
/// downloads in the same rows. A row on disk is picked at once; a row that is
/// not downloads and is picked when ready. `rows` go under the list: the model
/// for files and calls and the unload delay. The downloads belong to
/// `VoiceModelsController`, so closing the window leaves them running.
struct ModelsList<Rows: View>: View {
    let controller: VoiceModelsController
    @ViewBuilder var rows: Rows

    @Namespace private var choiceSpace

    private var recognizers: [VoiceModelStatus] {
        controller.statuses.filter { $0.entry.engine.recognizes }
    }

    private var downloadsForbidden: Bool { controller.settings.managed.voiceModelDownloadsDisabled }

    private var chosen: String { controller.settings.settings.model }

    var body: some View {
        PKGroup(header: voiceText("Model"), anchor: "voice.models") {
            if downloadsForbidden {
                PKNote(voiceText("Your administrator turned off model downloads. Perekey reads models from the folder /Library/Application Support/Perekey/VoiceModels."))
                PKDivider()
            } else if !controller.settings.settings.isEnabled {
                PKNote(voiceText("Turn on voice input to download models."))
                PKDivider()
            }
            VStack(spacing: 2) {
                ForEach(recognizers) { status in
                    ModelOption(status: status, controller: controller, error: controller.errors[status.id],
                                isChosen: status.id == chosen, isPending: controller.pendingChoice == status.id,
                                choiceSpace: choiceSpace)
                }
            }
            .padding(6)
            .pkAnimation(PK.Motion.settle(0.45), value: chosen)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(voiceText("Dictation model"))
            PKDivider()
            rows
            PKDivider()
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    voiceText("Models run on this Mac. The network is only for downloads.")
                    diskText
                }
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
            if let failure = controller.deleteAllError {
                Text(verbatim: voiceString("Could not delete the models: \(failure)"))
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkRose)
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
        controller.keptByDeleteAll.compactMap { ModelCatalog.entry(id: $0).map(ModelNames.display) }.joined(separator: ", ")
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

enum ModelNames {
    /// The name for people: the catalog's title without the variant's size, "(632 MB)".
    static func display(_ entry: VoiceModelEntry) -> String {
        guard let open = entry.title.range(of: " (", options: .backwards), entry.title.hasSuffix(" MB)") || entry.title.hasSuffix(" GB)")
        else { return entry.title }
        return String(entry.title[..<open.lowerBound])
    }

    /// What sets the model apart, in one line: from the stage 0 E checks.
    static func tagline(_ entry: VoiceModelEntry) -> Text? {
        switch entry.id {
        case "parakeet-tdt-v3": voiceText("Fast. 25 European languages; English terms stay in Latin letters.")
        case "parakeet-ultra": voiceText("A retrained v3. The same 25 languages; English words in a Russian phrase come out in Cyrillic.")
        case _ where entry.engine == .whisperKit: voiceText("Almost any language. Slower; after the download it gets ready for about 10 minutes.")
        default: nil
        }
    }
}

enum ModelSize {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One model of the choice. The radio and the text pick it; the trailing
/// button downloads, stops or deletes it. The chosen row carries the strip,
/// which slides from row to row.
private struct ModelOption: View {
    let status: VoiceModelStatus
    let controller: VoiceModelsController
    let error: VoiceModelFailure?
    let isChosen: Bool
    let isPending: Bool
    let choiceSpace: Namespace.ID

    private let hovered = State(initialValue: false)

    private var title: String { ModelNames.display(status.entry) }
    private var forbidden: Bool { controller.settings.managed.voiceModelDownloadsDisabled }
    private var isReady: Bool { status.state == .ready }

    /// A click on the row does something: picks a model on disk or downloads one.
    private var canChoose: Bool {
        if isReady { return !isChosen }
        if status.isDownloading { return !isChosen && !isPending }
        if case .damaged = status.state, status.isInUse { return false }
        return !forbidden && controller.canDownload
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { controller.choose(status.id) } label: {
                HStack(alignment: .center, spacing: 12) {
                    ChoiceMark(chosen: isChosen, available: isReady, pending: isPending)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: title)
                                .font(isChosen ? PK.Font.bodyStrong : PK.Font.body)
                                .foregroundStyle(Color.pkInk)
                            if status.id == VoiceSettings.defaultModel { PKTag(text: voiceText("recommended")) }
                            if status.isManaged { PKTag(text: voiceText("from your administrator")) }
                        }
                        if let tagline = ModelNames.tagline(status.entry) {
                            tagline.font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        stateLine
                        if let failure = status.failure ?? error {
                            Text(verbatim: ModelFailureText.text(failure))
                                .font(PK.Font.caption)
                                .foregroundStyle(Color.pkRose)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Not `disabled`: a row that is already chosen or on its way must not look turned off.
            .allowsHitTesting(canChoose)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(accessibilityState)
            .accessibilityHint(isReady ? voiceText("Dictate with this model") : voiceText("Download the model and dictate with it"))
            .accessibilityAddTraits(isChosen ? .isSelected : [])
            trailing
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
        .background {
            if isChosen {
                Color.clear
                    .glassStrip(in: RoundedRectangle(cornerRadius: PK.Radius.segment, style: .continuous))
                    .matchedGeometryEffect(id: "choice", in: choiceSpace)
            } else if hovered.wrappedValue, canChoose {
                RoundedRectangle(cornerRadius: PK.Radius.segment, style: .continuous).fill(Color.pkWash)
            }
        }
        .onHover { hovered.wrappedValue = $0 }
        .pkAnimation(PK.Motion.easeOut(0.15), value: hovered.wrappedValue)
        .pkAnimation(PK.Motion.easeOut(0.32), value: StateKind(status.state))
    }

    // MARK: State

    @ViewBuilder private var stateLine: some View {
        switch status.state {
        case .absent:
            if isChosen { line(voiceText("Not downloaded. Download it to dictate."), color: .pkWarn) }
        case let .partial(received):
            line(voiceText("Paused at \(percent(received))"))
        case let .downloading(received):
            progressLine(received: received, waiting: false)
        case let .waitingForNetwork(received):
            progressLine(received: received, waiting: true)
        case .ready:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.pkOK)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .accessibilityHidden(true)
                Text(verbatim: voiceString("Ready · \(ModelSize.text(status.entry.totalSize))"))
                    .foregroundStyle(Color.pkInk2)
            }
            .font(PK.Font.caption)
        case .damaged:
            line(voiceText("Files are damaged or missing"), color: .pkWarn)
        }
    }

    private func line(_ text: Text, color: Color = .pkInk2) -> some View {
        text.font(PK.Font.caption).foregroundStyle(color)
    }

    private func progressLine(received: Int64, waiting: Bool) -> some View {
        // Percent and bytes share one denominator: the model's own files.
        let total = ModelSize.text(status.entry.totalSize)
        return VStack(alignment: .leading, spacing: 2) {
            if waiting {
                line(voiceText("Waiting for the network… \(percent(received))"), color: .pkWarn)
            } else {
                Text(verbatim: voiceString("\(ModelSize.text(received)) of \(total)"))
                    .font(PK.Font.caption.monospacedDigit())
                    .foregroundStyle(Color.pkInk2)
                    .contentTransition(.numericText())
            }
            if isPending {
                line(voiceText("Perekey switches to it when it is downloaded."), color: .pkIndigoInk)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceText("Downloading \(title)"))
        .accessibilityValue(waiting
                            ? voiceText("Waiting for the network, \(percent(received))")
                            : Text(verbatim: percent(received)))
    }

    private var accessibilityState: Text {
        switch status.state {
        case .ready: voiceText("Ready")
        case .absent: Text(verbatim: voiceString("Not downloaded, \(ModelSize.text(status.size))"))
        case let .partial(received): voiceText("Paused at \(percent(received))")
        case let .downloading(received), let .waitingForNetwork(received): voiceText("Downloading \(percent(received))")
        case .damaged: voiceText("Files are damaged or missing")
        }
    }

    private func percent(_ received: Int64) -> String {
        let fraction = status.entry.totalSize > 0 ? min(1, Double(received) / Double(status.entry.totalSize)) : 0
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Trailing

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 8) {
            switch status.state {
            case .absent:
                Text(verbatim: ModelSize.text(status.size)).font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                if !forbidden {
                    // One filled button: the chosen model's, the one dictation waits for.
                    action(voiceText("Download"), label: voiceString("Download \(title)"), primary: isChosen,
                           enabled: controller.canDownload) { controller.download(status.id) }
                }
            case .partial:
                if !forbidden {
                    action(voiceText("Resume"), label: voiceString("Resume downloading \(title)"), primary: isChosen,
                           enabled: controller.canDownload) { controller.download(status.id) }
                }
                deleteButton
            case .downloading, .waitingForNetwork:
                DownloadRing(fraction: status.progress ?? 0, waiting: isWaiting) {
                    controller.cancel(status.id)
                }
                .help(voiceText("Stop the download"))
                .accessibilityLabel(Text(verbatim: voiceString("Cancel downloading \(title)")))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .ready:
                deleteButton
            case .damaged:
                if !forbidden {
                    action(voiceText("Repair"), label: voiceString("Repair \(title)"), primary: true,
                           enabled: controller.canDownload && !status.isInUse,
                           help: status.isInUse ? voiceText("The model is in use. Repair it when dictation is done.") : nil) {
                        controller.download(status.id)
                    }
                }
                deleteButton
            }
        }
    }

    private var isWaiting: Bool {
        if case .waitingForNetwork = status.state { return true }
        return false
    }

    @ViewBuilder private var deleteButton: some View {
        if !status.isManaged {
            Button { controller.delete(status.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle())
            .disabled(status.isInUse)
            .help(status.isInUse ? voiceText("The model is in use. Delete it when dictation is done.") : voiceText("Delete the model files"))
            .accessibilityLabel(Text(verbatim: voiceString("Delete \(title)")))
        }
    }

    private func action(_ text: Text, label: String, primary: Bool = false, enabled: Bool = true,
                        help: Text? = nil, _ run: @escaping () -> Void) -> some View
    {
        Button(action: run) { text }
            .buttonStyle(PKButtonStyle(kind: primary ? .primary : .secondary, small: true))
            .disabled(!enabled)
            .help(help ?? Text(verbatim: ""))
            .accessibilityLabel(Text(verbatim: label))
    }
}

/// The state without the bytes: what changes the row's shape, not every
/// progress tick.
private enum StateKind: Equatable {
    case absent, partial, downloading, waiting, ready, damaged

    init(_ state: VoiceModelState) {
        switch state {
        case .absent: self = .absent
        case .partial: self = .partial
        case .downloading: self = .downloading
        case .waitingForNetwork: self = .waiting
        case .ready: self = .ready
        case .damaged: self = .damaged
        }
    }
}

/// The radio of a model: a filled indigo disc with a white dot when chosen, a
/// ring when on disk, a dashed ring when not downloaded yet.
private struct ChoiceMark: View {
    let chosen: Bool
    let available: Bool
    let pending: Bool

    var body: some View {
        ZStack {
            if chosen {
                Circle().fill(Color.pkIndigoFill)
                Circle().fill(.white).frame(width: 6, height: 6)
                    .transition(.scale(scale: 0.2))
            } else if available {
                Circle().strokeBorder(Color.pkInk3, lineWidth: 1.5)
            } else {
                Circle().strokeBorder(pending ? Color.pkIndigo : Color.pkInk3,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5]))
            }
        }
        .frame(width: 16, height: 16)
        .pkAnimation(PK.Motion.spring, value: chosen)
        .accessibilityHidden(true)
    }
}

/// A download in progress: an indigo ring that fills, with a stop square in
/// the middle that cancels it. Waiting for the network, the ring turns amber.
private struct DownloadRing: View {
    let fraction: Double
    let waiting: Bool
    let cancel: () -> Void

    var body: some View {
        Button(action: cancel) {
            ZStack {
                Circle().stroke(Color.pkWashDeep, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(waiting ? Color.pkWarn : Color.pkIndigo, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .pkAnimation(PK.Motion.easeOut(0.5), value: fraction)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(waiting ? Color.pkWarn : Color.pkIndigo)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 22, height: 22)
            .padding(2)
            .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle(round: true))
    }
}

/// A quiet glyph button: Secondary Ink, Wash on hover and press.
private struct IconButtonStyle: ButtonStyle {
    var round = false

    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration, round: round)
    }

    private struct IconButton: View {
        let configuration: ButtonStyleConfiguration
        let round: Bool
        private let hovered = State(initialValue: false)
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Color.pkInk2 : Color.pkInk3)
                .background {
                    if round {
                        Circle().fill(hovered.wrappedValue || configuration.isPressed ? Color.pkWash : .clear)
                    } else {
                        RoundedRectangle(cornerRadius: PK.Radius.popup, style: .continuous)
                            .fill(hovered.wrappedValue || configuration.isPressed ? Color.pkWash : .clear)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .onHover { hovered.wrappedValue = $0 && isEnabled }
                .pkAnimation(PK.Motion.press, value: configuration.isPressed)
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
