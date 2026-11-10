// SPDX-License-Identifier: GPL-3.0-or-later
//
// Drives the spike input method through the real text system of this
// process's own windows and compares the text with the reference: the same
// Composer over an in-memory BufferClient, so any difference is the
// mechanism's (lost, doubled, reordered or misplaced letters), not the
// classifier's.
//
//   imk-harness sources
//       the keyboard input sources a text view may select, and the current one
//   imk-harness run [--target textview|searchfield|web-input|web-textarea]
//                   [--words N] [--rate KEYS_PER_SECOND] [--mode MODE_ID] [--strategy marked|replace]
//       types N words at the given rate and prints the result as key=value lines
//
// The input method reads its strategy from its own defaults
// (`defaults write app.perekey.inputmethod.Spike strategy …`); --strategy
// only sets the reference, so pass the same value to both.

import AppKit
import PerekeyCore
import PerekeyInput
import SpikeCore
import WebKit

// MARK: - Words

let russianWords = """
    привет мир будет когда сейчас работа потом хорошо спасибо вопрос сегодня завтра человек время \
    жизнь дело город слово место лицо друг глаза вода машина письмо ответ решение новости \
    кстати конечно может нужно можно очень тоже просто давай пока вечером утром
    """.split(separator: " ").map(String.init)
let englishWords = """
    hello world when then work good thanks question later right today tomorrow people time \
    life thing city word place face friend water letter answer decision news meeting \
    anyway course maybe need could very also just please while evening morning
    """.split(separator: " ").map(String.init)

struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The key strokes of N words, each in the layout it is meant in, with a space after each.
func script(words: Int, latin: LayoutMap, cyrillic: LayoutMap) -> [KeyStroke] {
    var random = SplitMix(state: 2026)
    var strokes: [KeyStroke] = []
    for _ in 0..<words {
        let russian = random.next() % 2 == 0
        let list = russian ? russianWords : englishWords
        let word = list[Int(random.next() % UInt64(list.count))]
        let layout = russian ? cyrillic : latin
        strokes += word.compactMap { layout.stroke(for: $0) }
        strokes.append(KeyStroke(KeyCode.space))
    }
    return strokes
}

// MARK: - Options

var options: [String: String] = [:]
var command = "run"
do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if let first = arguments.first, !first.hasPrefix("--") { command = first; arguments.removeFirst() }
    while arguments.count >= 2, arguments[0].hasPrefix("--") {
        options[String(arguments[0].dropFirst(2))] = arguments[1]
        arguments.removeFirst(2)
    }
}
let target = options["target"] ?? "textview"
let wordCount = Int(options["words"] ?? "1000") ?? 1000
let rate = Double(options["rate"] ?? "30") ?? 30
let mode = options["mode"] ?? "app.perekey.inputmethod.Spike.en"
let strategy = Strategy(rawValue: options["strategy"] ?? "replace") ?? .replace

func say(_ key: String, _ value: Any) {
    print("\(key)=\(value)")
    fflush(stdout)
}

// MARK: - Harness

@MainActor
final class Harness: NSObject, NSSearchFieldDelegate, WKScriptMessageHandler {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    var textView: NSTextView?
    var searchField: NSSearchField?
    var webView: WKWebView?
    /// What a search-as-you-type field saw: the value at each change notification.
    var changes: [String] = []
    var webLoaded = false

    func setUp() {
        switch target {
        case "textview":
            let view = NSTextView(frame: window.contentView!.bounds)
            window.contentView = view
            textView = view
        case "searchfield":
            let field = NSSearchField(frame: NSRect(x: 10, y: 10, width: 600, height: 24))
            field.delegate = self
            window.contentView!.addSubview(field)
            searchField = field
        default:
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.add(self, name: "change")
            let view = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
            window.contentView = view
            let field = target == "web-textarea" ? "<textarea id=f rows=20 cols=80></textarea>" : "<input id=f size=80>"
            view.loadHTMLString("""
                <html><body>\(field)<script>
                const f = document.getElementById('f');
                f.addEventListener('input', e => webkit.messageHandlers.change.postMessage(
                    (e.isComposing ? 'composing:' : 'input:') + f.value));
                f.focus();
                </script></body></html>
                """, baseURL: nil)
            webView = view
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var responder: NSView? {
        if let textView { return textView }
        if let searchField { return searchField.currentEditor() as? NSTextView }
        return webView
    }

    func focus() {
        if let textView { window.makeFirstResponder(textView) }
        if let searchField { window.makeFirstResponder(searchField) }
        if let webView { window.makeFirstResponder(webView) }
    }

    func report(sources context: NSTextInputContext?) {
        say("app_active", NSApp.isActive)
        say("window_key", window.isKeyWindow)
        say("context", context != nil)
        guard let context else { return }
        say("sources", (context.keyboardInputSources ?? []).joined(separator: ","))
        say("selected", context.selectedKeyboardInputSource ?? "nil")
    }

    func fieldText() async -> String {
        if let textView { return textView.string }
        if let searchField { return searchField.stringValue }
        if let webView { return (try? await webView.evaluateJavaScript("document.getElementById('f').value") as? String) ?? "" }
        return ""
    }

    func controlTextDidChange(_ notification: Notification) {
        changes.append(searchField?.stringValue ?? "")
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? String ?? ""
        MainActor.assumeIsolated { changes.append(body) }
    }

    func keyEvent(_ stroke: KeyStroke, down: Bool, layout: LayoutMap) -> NSEvent? {
        var flags: NSEvent.ModifierFlags = []
        if stroke.modifiers.contains(.shift) { flags.insert(.shift) }
        let characters = layout.text(for: stroke) ?? ""
        return NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                isARepeat: false, keyCode: stroke.keyCode)
    }

    func run() async {
        setUp()
        if webView != nil {
            for _ in 0..<50 where (try? await webView!.evaluateJavaScript("document.readyState") as? String) != "complete" {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        focus()
        guard let layouts = LayoutReader.enabledLayouts().first(where: { $0.language == "en" })
            .flatMap({ latin in LayoutReader.enabledLayouts().first(where: { $0.language == "ru" }).map { (latin, $0) } })
        else { say("error", "no Latin and Cyrillic layouts enabled"); return }
        let (latin, cyrillic) = layouts
        say("layouts", "\(latin.id.rawValue),\(cyrillic.id.rawValue)")
        let context = responder?.inputContext
        if command == "sources" { report(sources: context); return }

        // probe: the composer talks to the view's NSTextInputClient directly, as
        // IMK does on the client's side, without the input method process.
        var probe: (composer: Composer, client: InputClient)?
        if command == "probe" || command == "undo" || command == "autocomplete" {
            guard let view = responder as? NSTextInputClient else { say("result", "no NSTextInputClient"); return }
            probe = (Composer(strategy: strategy, latin: latin, cyrillic: cyrillic,
                              current: mode.hasSuffix(".ru") ? cyrillic.id : latin.id, decide: Self.decide),
                     InputClient(view))
        } else if command != "webquery" {
            context?.selectedKeyboardInputSource = mode
            context?.activate()
            report(sources: context)
            guard context?.selectedKeyboardInputSource == mode else {
                say("result", "the text input context did not take \(mode)")
                return
            }
        }
        if command == "webquery" { await webQuery(); return }
        if command == "undo", let probe { await undo(probe, latin: latin); return }
        if command == "autocomplete", let probe { await autocomplete(probe, latin: latin, cyrillic: cyrillic); return }

        // The reference: the same composer over an in-memory field.
        let decide = Self.decide
        let strokes = script(words: wordCount, latin: latin, cyrillic: cyrillic)
        let reference = BufferClient()
        let referenceComposer = Composer(strategy: strategy, latin: latin, cyrillic: cyrillic,
                                         current: mode.hasSuffix(".ru") ? cyrillic.id : latin.id, decide: decide)
        for stroke in strokes { _ = referenceComposer.key(stroke, command: false, client: reference) }
        say("model", Self.classifier != nil)
        say("keys", strokes.count)

        // Typed with the ABC characters: the input method reads key codes, not characters.
        let interval = 1.0 / rate
        let start = ProcessInfo.processInfo.systemUptime
        for (index, stroke) in strokes.enumerated() {
            if let probe {
                _ = probe.composer.key(stroke, command: false, client: probe.client)
            } else {
                if let down = keyEvent(stroke, down: true, layout: latin) { responder?.keyDown(with: down) }
                if let up = keyEvent(stroke, down: false, layout: latin) { responder?.keyUp(with: up) }
            }
            let due = start + Double(index + 1) * interval
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        let typed = ProcessInfo.processInfo.systemUptime - start
        // Let the last replies of the input method arrive.
        var text = await fieldText()
        let settleStart = ProcessInfo.processInfo.systemUptime
        while text != reference.committed, ProcessInfo.processInfo.systemUptime - settleStart < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            text = await fieldText()
        }
        say("typed_seconds", String(format: "%.1f", typed))
        say("settle_ms", Int((ProcessInfo.processInfo.systemUptime - settleStart) * 1000))
        say("reference_switched", referenceComposer.stats.switched)
        say("expected_chars", (reference.committed as NSString).length)
        say("actual_chars", (text as NSString).length)
        let difference = diff(reference.committed, text)
        say("differing_words", difference.count)
        for line in difference.prefix(10) { say("diff", line) }
        if !changes.isEmpty {
            say("change_events", changes.count)
            say("composing_events", changes.filter { $0.hasPrefix("composing:") }.count)
            say("first_changes", changes.prefix(8).map { $0.replacingOccurrences(of: "\n", with: "⏎") }.joined(separator: " | "))
        }
        if let probe {
            let stats = probe.composer.stats
            say("stats", "switched \(stats.switched) replaced \(stats.replaced) refused \(stats.refused) "
                + "broken \(stats.broken) fellBack \(stats.fellBack)")
            say("query_wait_ms_total", Int(probe.client.waited * 1000))
            say("query_timeouts", probe.client.timeouts)
        }
        say("result", difference.isEmpty ? "same" : "different")
    }

    static let classifier: Classifier? = (try? ModelFile.load(modelPath, languages: ["en", "ru"])).map { Classifier(model: $0) }

    static func decide(_ strokes: [KeyStroke], _ typed: LayoutMap, _ other: LayoutMap) -> Bool {
        guard let classifier else { return false }
        if case .switch = classifier.classify(strokes, typed: typed, other: other).verdict { return true }
        return false
    }

    func type(_ text: String, on layout: LayoutMap, _ probe: (composer: Composer, client: InputClient)) async {
        for character in text {
            guard let stroke = layout.stroke(for: character) else { continue }
            _ = probe.composer.key(stroke, command: false, client: probe.client)
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    /// What WebKit answers to the queries IMK makes, synchronously and through
    /// `NSTextInputClient_Async`, and whether it honours a replacement range.
    func webQuery() async {
        guard let webView, let client = webView as NSView as? NSTextInputClient else { say("result", "needs a web target"); return }
        client.insertText("hello world", replacementRange: NSRange(location: NSNotFound, length: 0))
        try? await Task.sleep(for: .milliseconds(300))
        say("value", "«\(await fieldText())»")
        say("sync_selectedRange", NSStringFromRange(client.selectedRange()))
        say("sync_substring_0_5", client.attributedSubstring(forProposedRange: NSRange(location: 0, length: 5), actualRange: nil)?.string ?? "nil")
        let async = unsafeBitCast(webView, to: AsyncTextInput.self)
        say("responds_async", webView.responds(to: #selector(AsyncTextInput.selectedRange(completionHandler:))))
        let range: NSRange = await withCheckedContinuation { done in async.selectedRange { done.resume(returning: $0) } }
        say("async_selectedRange", NSStringFromRange(range))
        let text: String = await withCheckedContinuation { done in
            async.attributedSubstring(forProposedRange: NSRange(location: 6, length: 5)) { string, _ in done.resume(returning: string?.string ?? "nil") }
        }
        say("async_substring_6_5", text)
        client.insertText("WORLD", replacementRange: NSRange(location: 6, length: 5))
        try? await Task.sleep(for: .milliseconds(300))
        say("after_replace_6_5", "«\(await fieldText())»")
        client.insertText("HELLO", replacementRange: NSRange(location: 0, length: 5))
        try? await Task.sleep(for: .milliseconds(300))
        say("after_replace_0_5", "«\(await fieldText())»")
        let caret: NSRange = await withCheckedContinuation { done in async.selectedRange { done.resume(returning: $0) } }
        say("caret_after", NSStringFromRange(caret))
    }

    /// ⌘Z after a switched word: how many undo steps bring back the field before the word.
    func undo(_ probe: (composer: Composer, client: InputClient), latin: LayoutMap) async {
        await type("ghbdtn vbh ", on: latin, probe)
        say("before_undo", await fieldText())
        let manager = responder?.undoManager
        say("undo_manager", manager != nil)
        for step in 1...12 {
            guard let manager, manager.canUndo else { say("undo_exhausted_after", step - 1); break }
            if let webView {
                _ = try? await webView.evaluateJavaScript("document.execCommand('undo')")
            } else {
                manager.undo()
            }
            try? await Task.sleep(for: .milliseconds(100))
            say("undo_\(step)", "«\(await fieldText())»")
        }
    }

    /// An inline completion as browsers' address bars do it: on input, when the
    /// value is a prefix of a known address, the rest is added and selected.
    /// Pages do not complete while text is composed (`isComposing`).
    func autocomplete(_ probe: (composer: Composer, client: InputClient), latin: LayoutMap, cyrillic: LayoutMap) async {
        guard let webView else { say("result", "autocomplete needs --target web-input"); return }
        _ = try? await webView.evaluateJavaScript("""
            f.addEventListener('input', e => {
              if (e.isComposing || e.inputType.startsWith('delete')) return;
              for (const s of ['github.com', 'привет.рф']) {
                if (f.value.length > 0 && s.startsWith(f.value) && s !== f.value) {
                  const n = f.value.length; f.value = s; f.setSelectionRange(n, s.length); break;
                }
              }
            }); 0
            """)
        await type("git", on: latin, probe)
        say("after_git", "«\(await fieldText())» selection \(probe.client.selectedRange().map { NSStringFromRange($0) } ?? "nil")")
        await type("hub", on: latin, probe)
        say("after_github", "«\(await fieldText())»")
        _ = try? await webView.evaluateJavaScript("f.value=''; 0")
        await type("ghbdtn", on: cyrillic.id == probe.composer.current ? cyrillic : latin, probe)
        say("after_ghbdtn", "«\(await fieldText())» selection \(probe.client.selectedRange().map { NSStringFromRange($0) } ?? "nil")")
        if let stroke = latin.stroke(for: ".") { _ = probe.composer.key(stroke, command: false, client: probe.client) }
        try? await Task.sleep(for: .milliseconds(200))
        say("after_boundary", "«\(await fieldText())»")
        say("changes", changes.joined(separator: " | "))
        let stats = probe.composer.stats
        say("stats", "switched \(stats.switched) replaced \(stats.replaced) refused \(stats.refused) broken \(stats.broken)")
    }

    /// Word-by-word differences, as "index: expected → actual".
    func diff(_ expected: String, _ actual: String) -> [String] {
        let a = expected.split(separator: " ", omittingEmptySubsequences: false)
        let b = actual.split(separator: " ", omittingEmptySubsequences: false)
        var lines: [String] = []
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? String(a[index]) : "∅"
            let y = index < b.count ? String(b[index]) : "∅"
            if x != y { lines.append("\(index): \(x) → \(y)") }
        }
        return lines
    }
}

/// The asynchronous half of WebKit's text input client (`NSTextInputClient_Async`).
@objc protocol AsyncTextInput {
    @objc(selectedRangeWithCompletionHandler:)
    func selectedRange(completionHandler: @escaping (NSRange) -> Void)
    @objc(attributedSubstringForProposedRange:completionHandler:)
    func attributedSubstring(forProposedRange range: NSRange, completionHandler: @escaping (NSAttributedString?, NSRange) -> Void)
}

/// A view's `NSTextInputClient` as the composer's client: what IMK calls on
/// the client's side of the connection.
@MainActor
final class InputClient: @MainActor TextClient {
    let view: NSTextInputClient

    init(_ view: NSTextInputClient) {
        self.view = view
    }

    func insert(_ text: String, replacing range: NSRange?) {
        view.insertText(text, replacementRange: range ?? NSRange(location: NSNotFound, length: 0))
    }

    func mark(_ text: String) {
        view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func selectedRange() -> NSRange? {
        var range = view.selectedRange()
        if range.location == NSNotFound, let async = asyncView {
            range = wait { done in async.selectedRange { done($0) } } ?? range
        }
        return range.location == NSNotFound ? nil : range
    }

    func text(in range: NSRange) -> String? {
        if let text = view.attributedSubstring(forProposedRange: range, actualRange: nil)?.string { return text }
        guard let async = asyncView else { return nil }
        return wait { done in async.attributedSubstring(forProposedRange: range) { text, _ in done(text?.string) } } ?? nil
    }

    var supportsDocumentAccess: Bool { true }

    /// WebKit answers queries only asynchronously; IMK's queries are synchronous
    /// for the input method. Spin the run loop until the answer, as a synchronous
    /// caller on the client's side must, up to `timeout`.
    static let timeout = 0.1
    /// How long the queries waited, in total, and how many timed out.
    var waited = 0.0
    var timeouts = 0

    private var asyncView: AsyncTextInput? {
        (view as AnyObject).responds(to: #selector(AsyncTextInput.selectedRange(completionHandler:)))
            ? unsafeBitCast(view as AnyObject, to: AsyncTextInput.self) : nil
    }

    private func wait<T>(_ ask: (@escaping (T) -> Void) -> Void) -> T? {
        var answer: T?
        var answered = false
        let start = ProcessInfo.processInfo.systemUptime
        ask { answer = $0; answered = true }
        while !answered, ProcessInfo.processInfo.systemUptime - start < Self.timeout {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        waited += ProcessInfo.processInfo.systemUptime - start
        if !answered { timeouts += 1 }
        return answer
    }
}

let modelPath = options["model"] ?? ProcessInfo.processInfo.environment["PEREKEY_MODEL"] ?? ""

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let harness = MainActor.assumeIsolated { Harness() }
Task { @MainActor in
    await harness.run()
    exit(0)
}
app.run()
