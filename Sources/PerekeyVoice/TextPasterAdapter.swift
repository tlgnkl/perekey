// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
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
}

extension DictationSecureInput: DictationSecureInputRules {}
