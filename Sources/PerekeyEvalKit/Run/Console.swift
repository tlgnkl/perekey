// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyDesk

/// What the commands print: a short summary of a run, and events one per line.
enum Console {
    static func summary(_ summary: Summary) -> String {
        var lines = ["suite × scenario                cases  exact  words   harm ‰  miss.layout ‰  botched ‰  rest ‰  rest0 ‰"]
        func row(_ name: String, _ metrics: Metrics) -> String {
            func rate(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
            return name.padding(toLength: 30, withPad: " ", startingAt: 0)
                + String(format: "%7d %6d %6d", metrics.cases, metrics.exact, metrics.words)
                + "  " + [rate(metrics.rates.harm), rate(metrics.rates.missLayout), rate(metrics.rates.botched),
                          rate(metrics.rates.rest), rate(metrics.rates.restNull)]
                .map { $0.leftPadded(to: 8) }.joined(separator: " ")
        }
        for group in summary.groups { lines.append(row("\(group.suite)  \(group.scenario)", group.metrics)) }
        lines.append(row("total", summary.total))
        let incidents = summary.incidents
        if incidents.fixed + incidents.open > 0 {
            lines.append("incidents: fixed \(incidents.fixedPassing) of \(incidents.fixed) pass; "
                + "waiting for a fix \(incidents.open), of them passing \(incidents.openPassing)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func describe(_ event: TypistEvent) -> String {
        switch event {
        case let .keyDown(keyCode, flags): "key down \(keyCode)\(flagNames(flags))"
        case let .keyUp(keyCode, flags): "key up \(keyCode)\(flagNames(flags))"
        case let .flags(keyCode, flags): "flags \(keyCode)\(flagNames(flags))"
        case let .userLayout(id): "layout \(id)"
        case let .click(target): "click \(target)"
        case let .focus(focus): "focus \(focus.bundleID ?? "-") secure \(focus.isSecureField) known \(focus.isKnown)"
        case let .mode(mode): "mode \(mode.rawValue)"
        case let .secureInput(on): "secure input \(on)"
        case let .capsLock(on): "caps lock \(on)"
        case let .select(chars): "select \(chars)"
        case .undoButton: "undo button"
        case let .idle(seconds): "idle \(seconds) s"
        }
    }

    static func describe(_ record: EvalDesk.Record) -> String {
        let input: String = switch record.input {
        case let .key(key, _):
            "\(key.phase == .down ? "down" : "up") \(key.keyCode)\(flagNames(key.flags)) \(origin(key.origin))"
        case let .flagsChanged(keyCode, flags, _, _, _): "flagsChanged \(keyCode)\(flagNames(flags))"
        case let .layoutChanged(id): "layoutChanged \(id)"
        case let .retypePosted(seq, _): "retypePosted \(seq)"
        case let .retypeCancelled(seq): "retypeCancelled \(seq)"
        case let .deadline(time): String(format: "deadline %.4f", time)
        case let .selectionRead(seq, text, _): "selectionRead \(seq) \(text.debugDescription)"
        default: "\(record.input)"
        }
        let effects = record.output.effects.map(effect).joined(separator: ", ")
        return "\(input) → \(record.output.disposition)" + (effects.isEmpty ? "" : " [\(effects)]")
            + "  text \(record.text.debugDescription) in \(record.layout)"
    }

    private static func effect(_ effect: Effect) -> String {
        switch effect {
        case let .selectLayout(id): "select \(id)"
        case let .retype(retype):
            "retype \(retype.seq): −\(retype.deleteCount) \(retype.text.debugDescription) → \(retype.target)"
        case let .corrected(correction):
            "corrected \(correction.seq) \(correction.kind): \(correction.original.debugDescription) → "
                + "\(correction.replacement.debugDescription)"
                + (correction.decision.map { " (\($0.reason), score \(String(format: "%.1f", $0.score)))" } ?? "")
        case let .correctionUndone(seq): "undone \(seq)"
        case let .scheduleDeadline(at): String(format: "deadline at %.4f", at)
        default: "\(effect)"
        }
    }

    private static func origin(_ origin: EventOrigin) -> String {
        switch origin {
        case .user: "user"
        case let .own(seq, last): "own \(seq)\(last ? " last" : "")"
        case .replayed: "replayed"
        }
    }

    private static func flagNames(_ flags: UInt64) -> String {
        var names: [String] = []
        if flags & EventFlags.shift != 0 { names.append("⇧") }
        if flags & EventFlags.control != 0 { names.append("⌃") }
        if flags & EventFlags.option != 0 { names.append("⌥") }
        if flags & EventFlags.command != 0 { names.append("⌘") }
        if flags & EventFlags.capsLock != 0 { names.append("⇪") }
        return names.isEmpty ? "" : " " + names.joined()
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: " ", count: length - count) + self
    }
}
