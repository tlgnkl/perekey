// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import PerekeyVoiceCore
import SwiftUI

// MARK: - Words

extension TranscriptAction {
    var title: String {
        switch self {
        case .summary: voiceString("Summary")
        case .minutes: voiceString("Meeting minutes")
        }
    }

    func progressText(_ share: Double) -> String {
        let percent = share.formatted(.percent.precision(.fractionLength(0)))
        return switch self {
        case .summary: voiceString("Writing the summary \(percent)")
        case .minutes: voiceString("Writing the minutes \(percent)")
        }
    }
}

extension SummaryFailure {
    var title: String {
        switch self {
        case .needsConsent: voiceString("Needs consent to send the transcript")
        case .needsModel: voiceString("No model for summaries")
        default: voiceString("No answer")
        }
    }

    var text: String {
        switch self {
        case .empty: voiceString("The transcript has no text.")
        case .voiceOff: voiceString("Voice input is off. Turn it on in Settings → Voice.")
        case .needsModel: voiceString("Set up a model on this Mac (Ollama or LM Studio) in the Voice modes tab, or pick one under Voice → Recordings.")
        case .cloudOff: voiceString("Your administrator turned off cloud models. Pick a model on this Mac.")
        case let .needsKey(endpoint): voiceString("\(endpoint) needs a key. Add it in the Voice modes tab.")
        case .needsConsent: voiceString("Nothing was sent. Allow sending the transcript to the server, or pick a model on this Mac.")
        case .modelFailed: voiceString("The language model did not answer. Check that it is running, then try again.")
        case .storageFailed: voiceString("Perekey could not save the answer.")
        }
    }
}

// MARK: - The switch

/// «Расшифровка · Конспект · Протокол встречи» above the right side.
struct TranscriptPanePicker: View {
    let controller: TranscriptsController

    var body: some View {
        Picker(selection: Binding(get: { controller.pane }, set: { controller.pane = $0 })) {
            voiceText("Transcript").tag(TranscriptsController.Pane.transcript)
            ForEach(TranscriptAction.allCases, id: \.self) { action in
                Text(verbatim: action.title).tag(TranscriptsController.Pane.note(action))
            }
        } label: {
            voiceText("Show")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, PK.Space.xl)
        .padding(.bottom, PK.Space.md)
    }
}

// MARK: - A summary or the minutes

struct TranscriptNotePane: View {
    let controller: TranscriptsController
    let summaries: TranscriptSummaries
    let item: RecordingItem
    let action: TranscriptAction
    private let confirmsReplace = State(initialValue: false)

    private var note: String? { controller.notes[action] }
    private var running: TranscriptSummaries.Running? { summaries.running[item.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let running {
                RunningStrip(action: running.action, progress: running.progress) { summaries.cancel(item.id) }
                Rectangle().fill(Color.pkRule).frame(height: 0.5)
            } else if let failure = summaries.failures[item.id] {
                Button { summaries.dismissFailure(item.id) } label: {
                    PKCallout(Text(verbatim: "\(failure.title). \(failure.text)"), symbol: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(verbatim: voiceString("Dismiss")))
            }
            if let note {
                toolbar
                Rectangle().fill(Color.pkRule).frame(height: 0.5)
                ScrollView {
                    MarkdownText(text: note)
                        .padding(.horizontal, PK.Space.xl)
                        .padding(.vertical, PK.Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if running?.action != action {
                offer
            } else {
                Spacer()
            }
        }
        .confirmationDialog(Text(verbatim: replaceQuestion), isPresented: confirmsReplace.projectedValue) {
            Button(role: .destructive) { controller.summarize(action) } label: { voiceText("Replace") }
        } message: {
            voiceText("The saved text is replaced with a new one.")
        }
    }

    private var replaceQuestion: String {
        switch action {
        case .summary: voiceString("Replace the summary?")
        case .minutes: voiceString("Replace the minutes?")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(verbatim: modelLine).font(PK.Font.caption).foregroundStyle(Color.pkInk2).lineLimit(1)
            Spacer(minLength: 8)
            Button { confirmsReplace.wrappedValue = true } label: { voiceText("Make again") }
                .buttonStyle(.pkSmall)
                .disabled(running != nil)
            Button { controller.export(action) } label: { voiceText("Export .md") }.buttonStyle(.pkSmall)
            Button { controller.copy(action) } label: { voiceText("Copy") }.buttonStyle(.pkSmall)
        }
        .padding(.horizontal, PK.Space.xl)
        .padding(.vertical, 8)
    }

    /// Where it runs: «Ollama · qwen2.5:7b» or the request to set one up.
    private var modelLine: String {
        guard let model = summaries.model else { return voiceString("No model for summaries") }
        return summaries.modes.title(of: model)
    }

    private var offer: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: action == .summary ? "text.badge.star" : "list.bullet.clipboard")
                .font(.system(size: 26)).foregroundStyle(Color.pkInk3).accessibilityHidden(true)
            Text(verbatim: action.title).font(PK.Font.headline).foregroundStyle(Color.pkInk)
            Text(verbatim: summaries.model == nil ? SummaryFailure.needsModel.text : voiceString("Runs on \(modelLine). The text is saved beside the transcript."))
                .font(PK.Font.caption).foregroundStyle(Color.pkInk2).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button { controller.summarize(action) } label: {
                Text(verbatim: action == .summary ? voiceString("Make a summary") : voiceString("Make the minutes"))
            }
            .buttonStyle(.pkPrimary)
            .disabled(running != nil || summaries.model == nil)
            Spacer()
        }
        .padding(PK.Space.xl)
        .frame(maxWidth: .infinity)
    }
}

/// «Пишу конспект 40 % · Стоп».
private struct RunningStrip: View {
    let action: TranscriptAction
    let progress: Double
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(verbatim: action.progressText(progress)).font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                .monospacedDigit()
            Spacer()
            ProgressView(value: progress).progressViewStyle(.linear).frame(width: 120).tint(Color.pkIndigo)
                .accessibilityHidden(true)
            Button(action: stop) { voiceText("Stop") }.buttonStyle(.pkSmall)
        }
        .padding(.horizontal, PK.Space.xl)
        .padding(.vertical, 8)
        .background(Color.pkWash)
        .accessibilityElement(children: .combine)
    }
}

/// The model's Markdown, line by line: headings, bullets, and inline marks
/// (bold, italics, code). Selectable, so a part can be copied.
private struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(line, level):
                    Self.inline(line).font(level <= 1 ? PK.Font.headline : PK.Font.bodyStrong)
                        .foregroundStyle(Color.pkInk)
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                case let .bullet(line, depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•").foregroundStyle(Color.pkInk3).accessibilityHidden(true)
                        Self.inline(line)
                    }
                    .font(PK.Font.body)
                    .foregroundStyle(Color.pkInk)
                    .padding(.leading, CGFloat(depth) * 14)
                case let .text(line):
                    Self.inline(line).font(PK.Font.body).foregroundStyle(Color.pkInk)
                }
            }
        }
        .textSelection(.enabled)
    }

    enum Block {
        case heading(String, level: Int)
        case bullet(String, depth: Int)
        case text(String)
    }

    static func blocks(_ text: String) -> [Block] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                return .heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces), level: level)
            }
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(2)), depth: indent / 2)
            }
            return .text(line)
        }
    }

    static func inline(_ line: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: line, options: options) { return Text(attributed) }
        return Text(verbatim: line)
    }
}
#endif
