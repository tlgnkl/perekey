// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyInput

/// `TextPaster` as dictation's paster: the one place that knows its API.
@MainActor
public final class TextPasterAdapter: DictationPaster {
    private let paster: TextPaster

    public init(_ paster: TextPaster) {
        self.paster = paster
    }

    public func captureTarget() async -> (any Sendable)? {
        await paster.captureTarget()
    }

    public func paste(_ text: String, into target: (any Sendable)?) async -> DictationPasteResult {
        // No target: there was no app in front when dictation started.
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
