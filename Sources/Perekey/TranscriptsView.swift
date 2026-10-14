// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyVoiceCore
import SwiftUI

// MARK: - Words

extension RecordingStatus {
    /// The short status of the list: «в очереди», «распознаю 34 %».
    var text: String {
        switch self {
        case .recording: voiceString("Recording")
        case .queued: voiceString("In the queue")
        case .preparingModel: voiceString("Preparing the model…")
        case let .transcribing(share): voiceString("Transcribing \(Self.percent(share))")
        case .waitingForDictation: voiceString("Waiting for dictation")
        case let .diarizing(share): voiceString("Telling speakers apart \(Self.percent(share))")
        case .done: voiceString("Done")
        case .failed(.needsConsent): voiceString("Needs consent to send the recording")
        case .failed: voiceString("Error")
        case .interrupted: voiceString("The recording was cut off")
        case .untranscribed: voiceString("Not transcribed")
        }
    }

    /// «34 %» in the person's locale.
    private static func percent(_ share: Double) -> String {
        min(1, max(0, share)).formatted(.percent.precision(.fractionLength(0)))
    }

    var tint: Color {
        switch self {
        case .failed(.needsConsent): .pkWarn
        case .failed: .pkRose
        case .interrupted: .pkWarn
        case .done: .pkOK
        case .recording: .pkRose
        default: .pkInk2
        }
    }
}

extension TranscriptionFailure {
    var text: String {
        switch self {
        case .sourceMissing: voiceString("The file is gone, or Perekey cannot open it.")
        case .unreadable: voiceString("The file has no audio, or it cannot be read.")
        case .modelUnavailable: voiceString("The model is not downloaded, or the cloud is off. Pick another model.")
        case .needsConsent: voiceString("A cloud model needs your consent to get the recording of a conversation. Transcribe again to be asked.")
        case .engineFailed: voiceString("The model failed on this audio.")
        case .storageFailed: voiceString("Perekey could not read or write the files of this recording.")
        case .newerVersion: voiceString("A newer version of Perekey made this recording. Update the app.")
        }
    }
}

extension TranscriptsController.Notice {
    var text: String {
        switch self {
        case let .sourceUnavailable(name): voiceString("Perekey cannot open “\(name)”. The file was moved or deleted.")
        case .nothingToPlay: voiceString("There is no sound at this place of the recording.")
        case .noAudio: voiceString("The audio of this recording is gone.")
        case let .notMedia(name): voiceString("“\(name)” is not an audio or video file.")
        case .queueUnavailable: voiceString("Transcription is not available yet.")
        case .storageFailed: voiceString("Perekey could not change the files of this recording.")
        case .exportFailed: voiceString("Perekey could not save the file.")
        case let .deleteAllFailed(count): voiceString("Could not delete \(count) recordings.")
        case .recordingInProgress: voiceString("The recording is going on.")
        case .deleteNotStopped: voiceString("Transcription did not stop, the recording is not deleted. Try again.")
        }
    }
}

enum TranscriptTime {
    /// `1:02:03` or `12:05`.
    static func duration(_ seconds: Double) -> String {
        let total = Int(min(max(0, seconds.isFinite ? seconds : 0), 1e9).rounded())
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// `00:01:23`, the stamp before a phrase.
    static func stamp(_ seconds: Double) -> String {
        let total = Int(min(max(0, seconds.isFinite ? seconds : 0), 1e9))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}

// MARK: - The window's content

struct TranscriptsView: View {
    let controller: TranscriptsController
    private let deleting = State<UUID?>(initialValue: nil)

    var body: some View {
        HStack(spacing: 0) {
            TranscriptsList(controller: controller, deleting: deleting.projectedValue)
                .frame(width: 280)
            Rectangle().fill(Color.pkRule).frame(width: 0.5)
            TranscriptDetail(controller: controller, deleting: deleting.projectedValue)
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(Color.pkPlate.opacity(0.35))
        .overlay { if controller.isDropTargeted { DropOverlay() } }
        .dropDestination(for: URL.self) { urls, _ in
            controller.drop(urls)
            return true
        } isTargeted: { controller.isDropTargeted = $0 }
        .confirmationDialog(voiceText("Delete this recording?"),
                            isPresented: Binding(get: { deleting.wrappedValue != nil },
                                                 set: { if !$0 { deleting.wrappedValue = nil } }),
                            presenting: deleting.wrappedValue)
        { id in
            Button(role: .destructive) { controller.delete(id) } label: { voiceText("Delete") }
        } message: { _ in
            voiceText("Its transcript and saved audio are deleted. A file you chose stays where it is.")
        }
        .onAppear { controller.reload() }
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous)
            .strokeBorder(Color.pkIndigo, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(Color.pkMist, in: RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous))
            .overlay { voiceText("Drop an audio or video file to transcribe it").font(PK.Font.headline).foregroundStyle(Color.pkIndigoInk) }
            .padding(10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - The list

private struct TranscriptsList: View {
    let controller: TranscriptsController
    let deleting: Binding<UUID?>

    var body: some View {
        if controller.items.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(Color.pkInk3).accessibilityHidden(true)
                voiceText("No transcripts yet").font(PK.Font.headline).foregroundStyle(Color.pkInk)
                voiceText("Drop an audio or video file here, and its text appears.")
                    .font(PK.Font.caption).foregroundStyle(Color.pkInk2).multilineTextAlignment(.center)
                Spacer()
            }
            .padding(PK.Space.xl)
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(controller.items) { item in
                        TranscriptRow(controller: controller, item: item, selected: controller.selection == item.id)
                            .contextMenu {
                                if item.status != .recording {
                                    Button(role: .destructive) { deleting.wrappedValue = item.id } label: { voiceText("Delete…") }
                                }
                            }
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct TranscriptRow: View {
    let controller: TranscriptsController
    let item: RecordingItem
    let selected: Bool

    private var summary: String {
        var parts: [String] = []
        if let duration = item.duration { parts.append(TranscriptTime.duration(duration)) }
        parts.append(item.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button { controller.selection = item.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: controller.title(of: item)).font(PK.Font.bodyStrong).foregroundStyle(Color.pkInk).lineLimit(1)
                Text(verbatim: item.status.text).font(PK.Font.caption).foregroundStyle(item.status.tint).lineLimit(1)
                if let progress = item.status.progress {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(Color.pkIndigo)
                        .accessibilityHidden(true)
                }
                Text(verbatim: summary).font(PK.Font.caption).foregroundStyle(Color.pkInk3).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PK.Radius.segment, style: .continuous)
                .fill(selected ? Color.pkMist : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(controller.title(of: item)), \(item.status.text), \(summary)"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - The chosen recording

private struct TranscriptDetail: View {
    let controller: TranscriptsController
    let deleting: Binding<UUID?>

    var body: some View {
        if let item = controller.selected {
            VStack(alignment: .leading, spacing: 0) {
                TranscriptHeader(controller: controller, item: item, deleting: deleting)
                Rectangle().fill(Color.pkRule).frame(height: 0.5)
                if let notice = controller.notice {
                    Button { controller.dismissNotice() } label: {
                        PKCallout(Text(verbatim: notice.text), symbol: "info.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(verbatim: voiceString("Dismiss")))
                }
                TranscriptBody(controller: controller, item: item)
            }
        } else {
            VStack {
                Spacer()
                voiceText("Pick a transcript on the left.").font(PK.Font.callout).foregroundStyle(Color.pkInk2)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct TranscriptHeader: View {
    let controller: TranscriptsController
    let item: RecordingItem
    let deleting: Binding<UUID?>
    @FocusState private var searchFocused: Bool

    private var subtitle: String {
        var parts = [item.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = item.duration { parts.append(TranscriptTime.duration(duration)) }
        if let document = controller.document {
            if let entry = ModelCatalog.entry(id: document.model) { parts.append(ModelNames.display(entry)) } else { parts.append(document.model) }
            if let language = document.language { parts.append(language.uppercased()) }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: controller.title(of: item)).font(PK.Font.headline).foregroundStyle(Color.pkInk).lineLimit(1)
                    Text(verbatim: subtitle).font(PK.Font.caption).foregroundStyle(Color.pkInk2).lineLimit(1)
                }
                Spacer(minLength: 8)
                if item.status.isPending {
                    Button { controller.cancel(item.id) } label: { voiceText("Stop") }.buttonStyle(.pkSmall)
                }
                if controller.document != nil {
                    if item.capabilities.canRetranscribe { retranscribeMenu }
                    exportMenu
                    Button { controller.copyAll() } label: { voiceText("Copy all") }.buttonStyle(.pkSmall)
                }
                Button { deleting.wrappedValue = item.id } label: { Image(systemName: "trash") }
                    .buttonStyle(.pkSmall)
                    .disabled(item.status == .recording)
                    .help(voiceText("Delete…"))
                    .accessibilityLabel(voiceText("Delete…"))
            }
            if controller.document != nil { searchField }
        }
        .padding(.horizontal, PK.Space.xl)
        .padding(.vertical, PK.Space.lg)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.pkInk3).accessibilityHidden(true)
                TextField("", text: Binding(get: { controller.query }, set: { controller.query = $0 }),
                          prompt: voiceText("Search the text"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(PK.Font.body)
                    .focused($searchFocused)
                    .onSubmit { controller.stepSearch(1) }
                    .accessibilityLabel(voiceText("Search the text"))
            }
            .padding(.horizontal, 8)
            .frame(width: 240, height: 26)
            .background(Color.pkPlate, in: RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous)
                .strokeBorder(searchFocused ? Color.pkIndigo : Color.pkRule, lineWidth: searchFocused ? 1 : 0.5))
            if !controller.query.trimmingCharacters(in: .whitespaces).isEmpty {
                let search = controller.search
                Text(verbatim: search.current.map { voiceString("\($0 + 1) of \(search.matches.count)") }
                    ?? voiceString("No matches"))
                    .font(PK.Font.caption).foregroundStyle(Color.pkInk2).monospacedDigit()
                    .accessibilityLabel(Text(verbatim: search.current.map { voiceString("Match \($0 + 1) of \(search.matches.count)") }
                        ?? voiceString("No matches")))
                Button { controller.stepSearch(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.pkSmall).disabled(search.matches.isEmpty)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .accessibilityLabel(voiceText("Previous match"))
                Button { controller.stepSearch(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.pkSmall).disabled(search.matches.isEmpty)
                    .keyboardShortcut("g", modifiers: .command)
                    .accessibilityLabel(voiceText("Next match"))
            }
        }
        .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden())
    }

    private var retranscribeMenu: some View {
        Menu {
            let models = controller.models()
            if models.isEmpty {
                Text(verbatim: voiceString("Download a model first."))
            }
            ForEach(models, id: \.id) { model in
                Button {
                    controller.retranscribe(model: model.id)
                } label: {
                    Text(verbatim: model.id == controller.document?.model ? voiceString("\(model.title) (now)") : model.title)
                }
            }
        } label: {
            voiceText("Transcribe again")
        }
        .menuStyle(.button)
        .buttonStyle(.pkSmall)
        .fixedSize()
        .disabled(!controller.canQueue)
        .help(voiceText("Transcribe again with another model. The old text is replaced."))
    }

    private var exportMenu: some View {
        Menu {
            ForEach(TranscriptFormat.allCases, id: \.self) { format in
                Button { controller.export(format) } label: { Text(verbatim: format.menuTitle) }
            }
        } label: {
            voiceText("Export")
        }
        .menuStyle(.button)
        .buttonStyle(.pkSmall)
        .fixedSize()
    }
}

extension TranscriptFormat {
    var menuTitle: String {
        switch self {
        case .txt: voiceString("Text (.txt)")
        case .md: voiceString("Markdown (.md)")
        case .srt: voiceString("Subtitles (.srt)")
        case .vtt: voiceString("Web subtitles (.vtt)")
        case .json: voiceString("Data (.json)")
        }
    }
}

// MARK: - The text

private struct TranscriptBody: View {
    let controller: TranscriptsController
    let item: RecordingItem

    var body: some View {
        switch controller.transcript {
        case let .loaded(document):
            VStack(alignment: .leading, spacing: 0) {
                if item.status.isPending || item.status == .interrupted || isFailed {
                    StatusStrip(controller: controller, item: item)
                    Rectangle().fill(Color.pkRule).frame(height: 0.5)
                }
                if item.meta.kind == .call, item.meta.audioRemovedAt != nil {
                    PKCallout(voiceText("The audio of this call was removed, so the text cannot be played or transcribed again."),
                              symbol: "speaker.slash", quiet: true)
                    Rectangle().fill(Color.pkRule).frame(height: 0.5)
                }
                SpeakersStrip(controller: controller, document: document)
                PhrasesList(controller: controller, item: item, document: document)
            }
        case .newer:
            Message(symbol: "exclamationmark.triangle", text: voiceString("A newer version of Perekey made this transcript. Update the app."))
        case .unreadable:
            Message(symbol: "exclamationmark.triangle", text: voiceString("Perekey cannot read this transcript."))
        case .none:
            noTranscript
        }
    }

    private var isFailed: Bool { if case .failed = item.status { true } else { false } }

    @ViewBuilder private var noTranscript: some View {
        switch item.status {
        case .queued, .preparingModel, .transcribing, .waitingForDictation, .diarizing:
            VStack(spacing: 12) {
                Spacer()
                if let progress = item.status.progress {
                    ProgressView(value: progress).progressViewStyle(.linear).frame(width: 220).tint(Color.pkIndigo)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(verbatim: item.status.text).font(PK.Font.callout).foregroundStyle(Color.pkInk2)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        case .interrupted:
            Offer(controller: controller, item: item, symbol: "exclamationmark.triangle",
                  title: voiceString("The recording was cut off"),
                  detail: item.capabilities.canResume ? voiceString("The sound written until then can still be turned into text.")
                      : voiceString("No sound was saved."))
        case let .failed(failure):
            Offer(controller: controller, item: item, symbol: failure == .needsConsent ? "hand.raised" : "xmark.octagon",
                  title: item.status.text, detail: failure.text)
        case .recording:
            Message(symbol: "record.circle", text: voiceString("The recording is going on."))
        case .done, .untranscribed:
            Offer(controller: controller, item: item, symbol: "text.alignleft", title: voiceString("Not transcribed"),
                  detail: item.capabilities.canResume ? nil : voiceString("No sound was saved."))
        }
    }
}

private struct Message: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Color.pkInk3).accessibilityHidden(true)
            Text(verbatim: text).font(PK.Font.callout).foregroundStyle(Color.pkInk2).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(PK.Space.xl)
        .frame(maxWidth: .infinity)
    }
}

/// «Запись прервалась · Расшифровать»: what happened, and the button.
private struct Offer: View {
    let controller: TranscriptsController
    let item: RecordingItem
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(item.status.tint).accessibilityHidden(true)
            Text(verbatim: title).font(PK.Font.headline).foregroundStyle(Color.pkInk)
            if let detail {
                Text(verbatim: detail).font(PK.Font.caption).foregroundStyle(Color.pkInk2).multilineTextAlignment(.center)
            }
            if item.capabilities.canResume {
                Button { controller.resume(item.id) } label: { voiceText("Transcribe") }
                    .buttonStyle(.pkPrimary)
                    .disabled(!controller.canQueue)
            }
            Spacer()
        }
        .padding(PK.Space.xl)
        .frame(maxWidth: .infinity)
    }
}

/// A transcript that is being replaced, or a failed or cut-off run of one that exists.
private struct StatusStrip: View {
    let controller: TranscriptsController
    let item: RecordingItem

    var body: some View {
        HStack(spacing: 10) {
            if item.status.isPending { ProgressView().controlSize(.small) }
            Text(verbatim: line).font(PK.Font.caption).foregroundStyle(item.status.tint)
            Spacer()
            if item.status.progress != nil {
                ProgressView(value: item.status.progress).progressViewStyle(.linear).frame(width: 120).tint(Color.pkIndigo)
            }
            if item.capabilities.canResume {
                Button { controller.resume(item.id) } label: { voiceText("Transcribe") }.buttonStyle(.pkSmall)
            }
        }
        .padding(.horizontal, PK.Space.xl)
        .padding(.vertical, 8)
        .background(Color.pkWash)
        .accessibilityElement(children: .combine)
    }

    private var line: String {
        if case let .failed(failure) = item.status { return failure.text }
        return item.status.text
    }
}

// MARK: Speakers

private struct SpeakersStrip: View {
    let controller: TranscriptsController
    let document: TranscriptDocument

    var body: some View {
        if !document.speakers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    voiceText("Speakers").font(PK.Font.captionStrong).foregroundStyle(Color.pkInk2)
                    ForEach(Array(document.speakers.enumerated()), id: \.element.id) { index, speaker in
                        SpeakerChip(controller: controller, speaker: speaker, color: SpeakerColor.of(index))
                    }
                }
                .padding(.horizontal, PK.Space.xl)
                .padding(.vertical, 8)
            }
            Rectangle().fill(Color.pkRule).frame(height: 0.5)
        }
    }
}

enum SpeakerColor {
    static func of(_ index: Int) -> Color {
        let palette: [Color] = [.pkIndigoInk, .pkOK, .pkWarn, .pkRose, .pkInk2]
        return palette[index % palette.count]
    }
}

private struct SpeakerChip: View {
    let controller: TranscriptsController
    let speaker: TranscriptSpeaker
    let color: Color
    private let editing = State(initialValue: false)
    private let draft = State(initialValue: "")

    var body: some View {
        Button {
            draft.wrappedValue = speaker.name ?? ""
            editing.wrappedValue = true
        } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(verbatim: controller.name(of: speaker)).font(PK.Font.caption).foregroundStyle(Color.pkInk)
                Image(systemName: "pencil").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.pkInk3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.pkWash))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: voiceString("Rename speaker \(controller.name(of: speaker))")))
        .popover(isPresented: editing.projectedValue, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                voiceText("Name of the speaker").font(PK.Font.captionStrong).foregroundStyle(Color.pkInk2)
                TextField("", text: draft.projectedValue, prompt: Text(verbatim: defaultName))
                    .labelsHidden()
                    .pkField()
                    .frame(width: 220)
                    .onSubmit(save)
                HStack {
                    Button { draft.wrappedValue = ""; save() } label: { voiceText("Reset") }.buttonStyle(.pkSmall)
                        .disabled(speaker.name == nil)
                    Spacer()
                    Button(action: save) { voiceText("Done") }.buttonStyle(.pkPrimary)
                }
            }
            .padding(PK.Space.lg)
        }
    }

    private var defaultName: String {
        var plain = speaker
        plain.name = nil
        return controller.name(of: plain)
    }

    private func save() {
        controller.rename(speaker: speaker.id, to: draft.wrappedValue)
        editing.wrappedValue = false
    }
}

// MARK: Phrases

private struct PhrasesList: View {
    let controller: TranscriptsController
    let item: RecordingItem
    let document: TranscriptDocument

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(document.segments.enumerated()), id: \.offset) { index, segment in
                        PhraseRow(controller: controller, index: index, segment: segment, document: document,
                                  canPlay: item.capabilities.canPlay)
                            .id(index)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: controller.search.currentMatch) { _, match in
                if let match { withAnimation(PK.Motion.easeOut(0.2)) { proxy.scrollTo(match.segment, anchor: .center) } }
            }
        }
    }
}

private struct PhraseRow: View {
    let controller: TranscriptsController
    let index: Int
    let segment: TimedSegment
    let document: TranscriptDocument
    let canPlay: Bool

    private var speakerIndex: Int? { document.speakers.firstIndex { $0.id == segment.speaker } }
    private var speakerName: String? {
        speakerIndex.map { controller.name(of: document.speakers[$0]) }
    }

    private var isPlaying: Bool {
        guard let second = controller.player.playingSecond else { return false }
        return segment.start <= second && second < max(segment.end, segment.start + 0.5)
    }

    var body: some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: TranscriptTime.stamp(segment.start))
                .font(PK.Font.caption.monospacedDigit()).foregroundStyle(Color.pkInk3)
            VStack(alignment: .leading, spacing: 2) {
                if let speakerName, let speakerIndex {
                    Text(verbatim: speakerName).font(PK.Font.captionStrong).foregroundStyle(SpeakerColor.of(speakerIndex))
                }
                Text(highlighted).font(PK.Font.body).foregroundStyle(Color.pkInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: PK.Radius.keycapSmall + 3, style: .continuous)
            .fill(isPlaying ? Color.pkMist : Color.clear))
        .contentShape(Rectangle())
        if canPlay {
            row
                .onTapGesture { controller.play(segment: index) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spoken))
                .accessibilityHint(voiceText("Plays the audio from here"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { controller.play(segment: index) }
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spoken))
        }
    }

    private var spoken: String {
        [TranscriptTime.stamp(segment.start), speakerName, segment.text].compactMap { $0 }.joined(separator: ", ")
    }

    /// The phrase with the search's hits marked; the current one stronger.
    private var highlighted: AttributedString {
        var text = AttributedString(segment.text)
        let current = controller.search.currentMatch
        for match in controller.search.matches(inSegment: index) {
            let characters = text.characters
            guard let lower = characters.index(characters.startIndex, offsetBy: match.lower, limitedBy: characters.endIndex),
                  let upper = characters.index(characters.startIndex, offsetBy: match.upper, limitedBy: characters.endIndex)
            else { continue }
            text[lower..<upper].backgroundColor = match == current ? Color.pkWarn.opacity(0.45) : Color.pkWarnSoft
        }
        return text
    }
}
#endif
