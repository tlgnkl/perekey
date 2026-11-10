// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import InputMethodKit
import os
import PerekeyCore
import PerekeyInput
import SpikeCore

let log = Logger(subsystem: "app.perekey.imspike", category: "im")

/// The input method's shared state: the two layouts, the classifier and the strategy.
@MainActor
enum Spike {
    static let bundleID = "app.perekey.inputmethod.Spike"
    static let latinMode = bundleID + ".en"
    static let cyrillicMode = bundleID + ".ru"

    /// The first enabled Latin and Cyrillic layouts, read through `UCKeyTranslate` (`LayoutReader`).
    static let layouts: (latin: LayoutMap, cyrillic: LayoutMap)? = {
        let enabled = LayoutReader.enabledLayouts()
        let latin = enabled.first { $0.language == "en" } ?? LayoutReader.installedLayout("com.apple.keylayout.ABC")
        let cyrillic = enabled.first { $0.language == "ru" } ?? LayoutReader.installedLayout("com.apple.keylayout.Russian")
        guard let latin, let cyrillic else { return nil }
        log.info("layouts \(latin.id.rawValue, privacy: .public) and \(cyrillic.id.rawValue, privacy: .public)")
        return (latin, cyrillic)
    }()

    static let classifier: Classifier? = {
        guard let path = Bundle.main.resourcePath else { return nil }
        do {
            return Classifier(model: try ModelFile.load(path, languages: ["en", "ru"]))
        } catch {
            log.error("no model: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()

    /// The strategy: `defaults write app.perekey.inputmethod.Spike strategy marked|replace`,
    /// read when a session starts.
    static var strategy: Strategy {
        UserDefaults.standard.string(forKey: "strategy").flatMap(Strategy.init(rawValue:)) ?? .replace
    }

    static func decide(_ strokes: [KeyStroke], _ typed: LayoutMap, _ other: LayoutMap) -> Bool {
        guard let classifier else { return false }
        if case .switch = classifier.classify(strokes, typed: typed, other: other).verdict { return true }
        return false
    }

    static func mode(of layout: LayoutMap) -> String {
        layout.language == "ru" ? cyrillicMode : latinMode
    }
}

/// `IMKTextInput` as the composer's client.
final class IMKClient: TextClient {
    let client: any IMKTextInput & NSObjectProtocol
    static let nowhere = NSRange(location: NSNotFound, length: NSNotFound)

    init(_ client: any IMKTextInput & NSObjectProtocol) {
        self.client = client
    }

    func insert(_ text: String, replacing range: NSRange?) {
        client.insertText(text, replacementRange: range ?? Self.nowhere)
    }

    func mark(_ text: String) {
        client.setMarkedText(text, selectionRange: NSRange(location: (text as NSString).length, length: 0),
                             replacementRange: Self.nowhere)
    }

    func selectedRange() -> NSRange? {
        let range = client.selectedRange()
        return range.location == NSNotFound ? nil : range
    }

    func text(in range: NSRange) -> String? {
        client.attributedSubstring(from: range)?.string
    }

    var supportsDocumentAccess: Bool {
        client.supportsProperty(TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag))
    }
}

/// One per input session (a text field of a client app).
@objc(PerekeyIMController)
final class PerekeyIMController: IMKInputController {
    private var composer: Composer?
    private var optionDown = false
    private var optionAlone = false
    private var keyEvents = 0
    private var flagEvents = 0

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            guard let client = sender as? any IMKTextInput & NSObjectProtocol, let layouts = Spike.layouts else { return }
            let composer = Composer(strategy: Spike.strategy, latin: layouts.latin, cyrillic: layouts.cyrillic,
                                    current: composer?.current ?? layouts.latin.id, decide: Spike.decide)
            composer.onSwitch = { layout in client.selectMode(Spike.mode(of: layout)) }
            self.composer = composer
            log.info("""
                activate \(client.bundleIdentifier() ?? "?", privacy: .public) \
                strategy \(composer.strategy.rawValue, privacy: .public) \
                documentAccess \(IMKClient(client).supportsDocumentAccess, privacy: .public)
                """)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            if let client = sender as? any IMKTextInput & NSObjectProtocol { composer?.commit(client: IMKClient(client)) }
            if let stats = composer?.stats { report(stats) }
        }
    }

    override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            guard let client = sender as? any IMKTextInput & NSObjectProtocol else { return }
            composer?.commit(client: IMKClient(client))
        }
    }

    /// The user picked a mode in the menu bar.
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        MainActor.assumeIsolated {
            guard tag == kTSMDocumentInputModePropertyTag, let mode = value as? String,
                  let client = sender as? any IMKTextInput & NSObjectProtocol, let layouts = Spike.layouts else { return }
            composer?.select(mode == Spike.cyrillicMode ? layouts.cyrillic.id : layouts.latin.id, client: IMKClient(client))
        }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        MainActor.assumeIsolated {
            guard let event, let composer, let raw = sender as? any IMKTextInput & NSObjectProtocol else { return false }
            let client = IMKClient(raw)
            let flags = event.modifierFlags
            if event.type == .flagsChanged {
                flagEvents += 1
                return optionTap(flags, client: client)
            }
            guard event.type == .keyDown else { return false }
            keyEvents += 1
            optionAlone = false
            var modifiers: LayoutModifiers = []
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
            if flags.contains(.option) { modifiers.insert(.option) }
            let command = !flags.isDisjoint(with: [.command, .control])
            return composer.key(KeyStroke(event.keyCode, modifiers), command: command, client: client)
        }
    }

    /// A tap of Option alone: down and up with no key between.
    @MainActor
    private func optionTap(_ flags: NSEvent.ModifierFlags, client: IMKClient) -> Bool {
        let option = flags.intersection(.deviceIndependentFlagsMask) == .option
        if option, !optionDown {
            optionDown = true
            optionAlone = true
            return false
        }
        defer { optionDown = flags.contains(.option); if !optionDown { optionAlone = false } }
        guard optionDown, !flags.contains(.option), optionAlone else { optionAlone = false; return false }
        _ = composer?.optionTap(client: client)
        return false
    }

    @MainActor
    private func report(_ stats: Composer.Stats) {
        log.info("""
            session keys \(self.keyEvents, privacy: .public) flags \(self.flagEvents, privacy: .public) \
            switched \(stats.switched, privacy: .public) replaced \(stats.replaced, privacy: .public) \
            refused \(stats.refused, privacy: .public) broken \(stats.broken, privacy: .public) \
            fellBack \(stats.fellBack, privacy: .public) manual \(stats.manual, privacy: .public)
            """)
    }
}
