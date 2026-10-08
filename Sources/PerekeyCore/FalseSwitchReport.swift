// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A pre-filled "False switch" GitHub issue, built from what the user agreed
/// to share. Nothing is sent: the app shows `fields` and `url` first, and
/// opens the link only when the user presses the button.
///
/// The field ids are those of `.github/ISSUE_TEMPLATE/false-switch.yml`.
/// The typed word is in the report only if the user keeps it
/// (`typed` non-empty); everything else is the layouts enabled and the versions.
public struct FalseSwitchReport: Hashable, Sendable {
    /// The options of the template's "Mode" dropdown, spelled as there.
    public enum Mode: String, CaseIterable, Hashable, Sendable {
        case automatic = "Automatic"
        case doubleShift = "Double Shift"
        case hotkey = "Hotkey"
        case other = "Other"
    }

    public struct Field: Hashable, Sendable {
        /// The id in the issue template, the name in the link.
        public var id: String
        /// The label of the template field.
        public var label: String
        public var value: String
    }

    public static let issueURL = "https://github.com/tlgnkl/perekey/issues/new"
    public static let template = "false-switch.yml"
    /// A word longer than this is not one; it would only fill the link.
    public static let maxWordLength = 64

    public var typed: String
    public var did: String
    /// What the classifier decided, as numbers and names only: see `summary(of:)`.
    public var reason: String
    public var mode: Mode
    public var layouts: [String]
    public var version: String

    /// - Parameters:
    ///   - typed: the word the user keeps in the report; empty to leave it out.
    ///   - did: what Perekey did, in the user's words; empty to leave it out.
    ///   - layouts: names of the enabled layouts.
    ///   - version: Perekey and macOS versions, e.g. "Perekey 0.4 (1), macOS 14.5".
    public init(typed: String = "", did: String = "", reason: String = "", mode: Mode = .hotkey,
                layouts: [String] = [], version: String = "")
    {
        self.reason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        self.typed = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxWordLength))
        self.did = String(did.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        self.mode = mode
        self.layouts = layouts
        self.version = version
    }

    /// What goes into the link, in the order of the template. Empty fields are left out.
    public var fields: [Field] {
        let all = [
            Field(id: "typed", label: "What you typed", value: typed),
            Field(id: "did", label: "What Perekey did", value: did),
            Field(id: "reason", label: "Classifier decision", value: reason),
            Field(id: "layouts", label: "Layouts enabled", value: layouts.joined(separator: ", ")),
            Field(id: "mode", label: "Mode", value: mode.rawValue),
            Field(id: "version", label: "Perekey and macOS version", value: version),
        ]
        return all.filter { !$0.value.isEmpty }
    }

    /// The link that opens the pre-filled issue form.
    public var url: URL {
        let items = [("template", Self.template)] + fields.map { ($0.id, $0.value) }
        let query = items.map { "\($0.0)=\(Self.escape($0.1))" }.joined(separator: "&")
        return URL(string: "\(Self.issueURL)?\(query)")!
    }

    /// The classifier's decision as a line of names and numbers, never text:
    /// «reason=compared score=38.2 threshold=10». Goes into the report so the
    /// maintainers see why a word was switched.
    public static func summary(of decision: Classifier.Decision) -> String {
        var parts = ["reason=\(decision.reason)"]
        if decision.score.isFinite { parts.append("score=\(String(format: "%.1f", decision.score))") }
        if decision.margin > 0 { parts.append("threshold=\(String(format: "%g", decision.margin))") }
        parts.append("typed=\(decision.typedForm)")
        parts.append("other=\(decision.otherForm)")
        return parts.joined(separator: " ")
    }

    /// The same for a correction: the decision, or what kind of fix it was.
    public static func summary(of correction: Correction) -> String {
        if correction.insideWord { return "kind=layout inside-word" }
        if let decision = correction.decision, case .switch = decision.verdict {
            var line = summary(of: decision)
            if correction.kind != .layout { line += " kind=\(correction.kind)" }
            if let change = correction.typoChange { line += " typo=\(change)" }
            return line
        }
        var line = "kind=\(correction.kind)"
        if let change = correction.typoChange { line += " typo=\(change)" }
        return line
    }

    /// A layout as the user knows it: "com.apple.keylayout.Russian" → "Russian".
    public static func layoutName(_ id: LayoutID) -> String {
        let prefix = "com.apple.keylayout."
        return id.rawValue.hasPrefix(prefix) ? String(id.rawValue.dropFirst(prefix.count)) : id.rawValue
    }

    /// Percent-encodes everything but unreserved characters, so `&`, `=`, `+`
    /// and `#` in a word cannot change the link.
    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
