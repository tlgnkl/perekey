// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import PerekeyVoiceCore

/// `TextPaster` as dictation's paster: the one place that knows its API.
@MainActor
public final class TextPasterAdapter: DictationPaster {
    private let paster: TextPaster

    public init(_ paster: TextPaster) {
        self.paster = paster
    }

    public var hasTarget: Bool { NSWorkspace.shared.frontmostApplication != nil }

    public func captureTarget() async -> (any Sendable)? {
        await paster.captureTarget()
    }

    public func caretContext(into target: (any Sendable)?) async -> String? {
        guard let target = target as? PasteTarget else { return nil }
        return await paster.textBeforeCaret(in: target)
    }

    public func application(of target: (any Sendable)?) -> DictationApplication? {
        guard let target = target as? PasteTarget,
              let app = NSRunningApplication(processIdentifier: target.pid) else { return nil }
        return DictationApplication(bundleID: app.bundleIdentifier, name: app.localizedName)
    }

    public func privacy(of target: (any Sendable)?) -> DictationPrivacy {
        if (target as? PasteTarget)?.isSecureField == true { return .secureField }
        if SecureInput.isEnabled { return .secureInput }
        // No element: the field cannot be told, so nothing of it is kept.
        return (target as? PasteTarget)?.element == nil ? .unknown : .normal
    }

    public func paste(_ text: String, into target: (any Sendable)?) async -> DictationPasteResult {
        // No app in front when dictation started: `hasTarget` keeps that
        // from starting, but the app may have quit in between.
        guard let target = target as? PasteTarget else { return .targetChanged }
        return switch await paster.paste(text, into: target) {
        case .pasted: .pasted
        case .targetChanged: .targetChanged
        case .secureField: .secureField
        case let .secureInput(owner): .secureInput(owner: owner.name)
        case .secureInputWhileTyping: .interruptedBySecureInput
        case .failed(.timedOut): .timedOut
        case .failed(.interrupted): .interrupted
        case let .failed(failure): .failed(String(describing: failure))
        }
    }

    /// Return on the target, marked as Perekey's own so the tap lets it
    /// through. Nothing when another app came to the front since the paste.
    public func pressReturn(in target: (any Sendable)?) async -> DictationPasteResult {
        guard let target = target as? PasteTarget else { return .targetChanged }
        return await Self.pressReturn(
            pid: target.pid, frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            wait: { try? await Task.sleep(for: .milliseconds(120)) }, post: Self.postReturn)
    }

    /// Return for the app `pid`, only while it is in front: before the wait
    /// for the paste to land and again after it, when another app may have
    /// come forward.
    static func pressReturn(pid: pid_t, frontmost: @MainActor () -> pid_t?, wait: () async -> Void,
                            post: () -> Void) async -> DictationPasteResult
    {
        guard frontmost() == pid else { return .targetChanged }
        // The app reads the pasted text first: events arrive in order, but
        // some apps handle ⌘V on their next turn of the run loop.
        await wait()
        guard frontmost() == pid else { return .targetChanged }
        post()
        return .pasted
    }

    /// Return, marked as Perekey's own so the tap lets it through.
    static func postReturn() {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: down) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticMark.own(seq: 0, last: !down).userData)
            event.post(tap: .cghidEventTap)
        }
    }
}

extension DictationSecureInput: DictationSecureInputRules {}
