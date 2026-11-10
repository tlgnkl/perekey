// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the composer needs from the text field: the part of `IMKTextInput`
/// the two strategies use. Ranges are UTF-16 and relative to the document.
public protocol TextClient: AnyObject {
    /// Inserts `text` over `range`, or at the selection (over the marked text, if any) when `range` is nil.
    func insert(_ text: String, replacing range: NSRange?)
    /// Shows `text` as marked text at the selection; the empty string clears it.
    func mark(_ text: String)
    /// The selection, or nil if the client cannot tell.
    func selectedRange() -> NSRange?
    /// The text of `range`, or nil if the client cannot tell.
    func text(in range: NSRange) -> String?
    /// The client says it answers document queries (`TSMDocumentAccess`).
    /// Without it, `IMKTextInput` ignores `replacementRange` (IMKInputSession.h).
    var supportsDocumentAccess: Bool { get }
}

/// A text field in memory that behaves like `NSTextView`: the model of a
/// client in tests and the reference the harness compares real fields with.
public final class BufferClient: TextClient {
    public var committed: String {
        didSet { caret = min(caret, (committed as NSString).length) }
    }
    public private(set) var marked = ""
    public private(set) var caret: Int
    /// How many insertions honoured a replacement range.
    public private(set) var replacements = 0
    public let supportsDocumentAccess: Bool
    /// Models a client that claims document access but inserts at the caret anyway.
    public let ignoresReplacement: Bool

    public init(committed: String = "", selection: Int? = nil, documentAccess: Bool = true,
                ignoresReplacement: Bool = false)
    {
        self.committed = committed
        caret = selection ?? (committed as NSString).length
        supportsDocumentAccess = documentAccess
        self.ignoresReplacement = ignoresReplacement
    }

    public func insert(_ text: String, replacing range: NSRange?) {
        let units = (text as NSString).length
        if let range, supportsDocumentAccess, !ignoresReplacement {
            marked = ""
            committed = (committed as NSString).replacingCharacters(in: range, with: text)
            caret = range.location + units
            replacements += 1
            return
        }
        marked = ""
        committed = (committed as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: text)
        caret += units
    }

    public func mark(_ text: String) {
        marked = text
    }

    public func selectedRange() -> NSRange? {
        supportsDocumentAccess ? NSRange(location: caret, length: 0) : nil
    }

    public func text(in range: NSRange) -> String? {
        guard supportsDocumentAccess, NSMaxRange(range) <= (committed as NSString).length else { return nil }
        return (committed as NSString).substring(with: range)
    }

    /// What the app does with a Backspace the input method passed on.
    public func deleteBackward() {
        guard caret > 0 else { return }
        let range = (committed as NSString).rangeOfComposedCharacterSequence(at: caret - 1)
        committed = (committed as NSString).replacingCharacters(in: range, with: "")
        caret = range.location
    }
}
