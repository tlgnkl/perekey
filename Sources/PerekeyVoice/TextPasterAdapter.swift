// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput

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

    public func paste(_ text: String, into target: (any Sendable)?) async -> DictationPasteResult {
        // No app in front when dictation started: `hasTarget` keeps that
        // from starting, but the app may have quit in between.
        guard let target = target as? PasteTarget else { return .targetChanged }
        return switch await paster.paste(text, into: target) {
        case .pasted: .pasted
        case .targetChanged: .targetChanged
        case .secureField: .secureField
        case let .secureInput(owner): .secureInput(owner: owner.name)
        case .failed(.timedOut): .timedOut
        case let .failed(failure): .failed(String(describing: failure))
        }
    }

    /// Return on the target, marked as Perekey's own so the tap lets it
    /// through. Nothing when another app came to the front since the paste.
    public func pressReturn(in target: (any Sendable)?) async -> DictationPasteResult {
        guard let target = target as? PasteTarget,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
        else { return .targetChanged }
        // The app reads the pasted text first: events arrive in order, but
        // some apps handle ⌘V on their next turn of the run loop.
        try? await Task.sleep(for: .milliseconds(120))
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: down) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticMark.own(seq: 0, last: !down).userData)
            event.post(tap: .cghidEventTap)
        }
        return .pasted
    }
}

extension DictationSecureInput: DictationSecureInputRules {}
