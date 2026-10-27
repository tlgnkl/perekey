// SPDX-License-Identifier: GPL-3.0-or-later

/// A block of the menu the user can show or hide (Settings → General → «Menu»).
/// The header with the layout, «Settings…» and «Quit» are not here: they always stay.
/// The order of the blocks is fixed by the menu.
public enum MenuBlock: String, CaseIterable, Hashable, Sendable, Codable {
    case modeCard
    case recentCorrections
    case recentDictations
    case pause
    case voiceMode
    case transcripts
    case transcribeFile
    case callRecording
    case updates
    case about
    case statistics
    case launchAtLogin
    case howTo
    case layoutsList

    /// Whether the block is in the menu until the user hides it. The rest are
    /// out until the user brings them in.
    public var shownByDefault: Bool {
        switch self {
        case .launchAtLogin, .howTo, .layoutsList: false
        default: true
        }
    }

    /// The blocks of the voice build: they show when their function is there.
    public var isVoice: Bool {
        switch self {
        case .recentDictations, .voiceMode, .transcripts, .transcribeFile, .callRecording: true
        default: false
        }
    }

    /// A block with a number of rows instead of a switch: 0 hides it.
    public var hasRows: Bool { self == .recentCorrections || self == .recentDictations }

    /// The rows a block with `hasRows` shows when the user did not choose.
    public var defaultRows: Int { self == .recentCorrections ? 5 : 3 }
}

/// Which blocks of the menu show. Only what differs from the defaults is kept,
/// so a block that a later version adds appears for people who never hid one.
public struct MenuLayout: Hashable, Sendable {
    /// The numbers of rows a list can have.
    public static let rowChoices = [0, 3, 5]

    /// Blocks that are out by default and the user brought in.
    public private(set) var shown: Set<MenuBlock> = []
    /// Blocks that are in by default and the user hid.
    public private(set) var hidden: Set<MenuBlock> = []
    /// The chosen rows of «Recent corrections» and «Recent dictations»; `nil`: the default.
    public private(set) var correctionRows: Int?
    public private(set) var dictationRows: Int?

    public init() {}

    /// Whether the user changed anything.
    public var isDefault: Bool {
        shown.isEmpty && hidden.isEmpty && correctionRows == nil && dictationRows == nil
    }

    public func shows(_ block: MenuBlock) -> Bool {
        block.hasRows ? rows(of: block) > 0 : (block.shownByDefault ? !hidden.contains(block) : shown.contains(block))
    }

    /// How many rows a list shows. Other blocks: 1 when shown, else 0.
    public func rows(of block: MenuBlock) -> Int {
        switch block {
        case .recentCorrections: correctionRows ?? block.defaultRows
        case .recentDictations: dictationRows ?? block.defaultRows
        default: shows(block) ? 1 : 0
        }
    }

    public mutating func set(_ block: MenuBlock, shown on: Bool) {
        if block.hasRows {
            setRows(on ? block.defaultRows : 0, of: block)
        } else if block.shownByDefault {
            if on { hidden.remove(block) } else { hidden.insert(block) }
        } else {
            if on { shown.insert(block) } else { shown.remove(block) }
        }
    }

    /// Sets the rows of a list to one of `rowChoices`; the default is not stored.
    public mutating func setRows(_ count: Int, of block: MenuBlock) {
        guard Self.rowChoices.contains(count) else { return }
        let stored: Int? = count == block.defaultRows ? nil : count
        switch block {
        case .recentCorrections: correctionRows = stored
        case .recentDictations: dictationRows = stored
        default: break
        }
    }

    public mutating func reset() { self = MenuLayout() }
}

extension MenuLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case shown, hidden, correctionRows, dictationRows
    }

    /// Names a version does not know (a block of a later one) are dropped.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func blocks(_ key: CodingKeys, _ wanted: Bool) -> Set<MenuBlock> {
            let names = try? container.decodeIfPresent([String].self, forKey: key)
            return Set((names ?? []).compactMap(MenuBlock.init(rawValue:))
                .filter { !$0.hasRows && $0.shownByDefault == wanted })
        }
        shown = blocks(.shown, false)
        hidden = blocks(.hidden, true)
        for block in [MenuBlock.recentCorrections, .recentDictations] {
            let key: CodingKeys = block == .recentCorrections ? .correctionRows : .dictationRows
            if let count = try? container.decodeIfPresent(Int.self, forKey: key) {
                setRows(count, of: block)
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !shown.isEmpty { try container.encode(shown.map(\.rawValue).sorted(), forKey: .shown) }
        if !hidden.isEmpty { try container.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden) }
        try container.encodeIfPresent(correctionRows, forKey: .correctionRows)
        try container.encodeIfPresent(dictationRows, forKey: .dictationRows)
    }
}

/// The height a menu may take: the room under the status item down to the screen's
/// visible edge, less a margin.
public enum MenuRoom {
    /// Between the item and the menu's top.
    public static let gap: Double = 4
    /// Left between the menu's bottom and the screen's.
    public static let bottomMargin: Double = 8

    /// `itemBottom` and `visibleBottom` are y of the screen, growing upward.
    public static func budget(itemBottom: Double, visibleBottom: Double) -> Double {
        max(0, itemBottom - gap - visibleBottom - bottomMargin)
    }
}
