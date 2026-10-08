// SPDX-License-Identifier: GPL-3.0-or-later

import Carbon
import PerekeyCore

/// Reads keyboard layouts from Text Input Sources.
///
/// Text Input Sources are not thread-safe (`TextInputSources.h`), so every
/// call runs on the main thread. The resulting `LayoutMap` values are
/// immutable and safe to hand to the event tap thread.
@MainActor
public enum LayoutReader {
    /// Keys that type text: the main block of an ANSI, ISO or JIS keyboard,
    /// without Return (36) and Tab (48).
    static let textKeyCodes: [UInt16] = (0...50).filter { $0 != KeyCode.return && $0 != KeyCode.tab }

    /// The enabled keyboard layouts, in the order the system lists them.
    /// Input methods and layouts without a `UCKeyTranslate` table (some virtual
    /// layouts, e.g. from Parallels) are skipped.
    public static func enabledLayouts() -> [LayoutMap] {
        sources(includeAllInstalled: false).compactMap { source in
            guard bool(source, kTISPropertyInputSourceIsEnabled),
                  bool(source, kTISPropertyInputSourceIsSelectCapable) else { return nil }
            return layoutMap(of: source)
        }
    }

    /// Any installed layout by its ID, enabled or not. For tools and tests.
    public static func installedLayout(_ id: LayoutID) -> LayoutMap? {
        sources(includeAllInstalled: true).first { string(of: $0, kTISPropertyInputSourceID) == id.rawValue }
            .flatMap(layoutMap(of:))
    }

    /// The ID of the selected keyboard input source.
    public static func currentLayoutID() -> LayoutID? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(of: source, kTISPropertyInputSourceID).map(LayoutID.init(rawValue:))
    }

    public static func layoutMap(of source: TISInputSource) -> LayoutMap? {
        guard let id = string(of: source, kTISPropertyInputSourceID),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
            .map { Unmanaged<CFArray>.fromOpaque($0).takeUnretainedValue() as? [String] ?? [] } ?? []

        var table: [KeyStroke: String] = [:]
        var deadKeys: Set<KeyStroke> = []
        let translated: Bool = data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return false }
            for keyCode in textKeyCodes {
                for modifiers in LayoutModifiers.allCombinations {
                    let stroke = KeyStroke(keyCode, modifiers)
                    switch translate(layout, stroke) {
                    case let .text(text): table[stroke] = text
                    case .dead: deadKeys.insert(stroke)
                    case .nothing: break
                    }
                }
            }
            return true
        }
        guard translated, !table.isEmpty else { return nil }
        return LayoutMap(id: LayoutID(rawValue: id), language: languages.first, table: table, deadKeys: deadKeys)
    }

    private enum Translation { case text(String), dead, nothing }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ stroke: KeyStroke) -> Translation {
        // Carbon modifier bits (`Events.h`) shifted right by 8, as UCKeyTranslate expects.
        var state: UInt32 = 0
        if stroke.modifiers.contains(.shift) { state |= UInt32(shiftKey >> 8) }
        if stroke.modifiers.contains(.capsLock) { state |= UInt32(alphaLock >> 8) }
        if stroke.modifiers.contains(.option) { state |= UInt32(optionKey >> 8) }

        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, stroke.keyCode, UInt16(kUCKeyActionDown), state,
                                    UInt32(LMGetKbdType()), 0, &deadKeyState, chars.count, &length, &chars)
        guard status == noErr else { return .nothing }
        if deadKeyState != 0 { return .dead }
        let text = String(utf16CodeUnits: chars, count: length)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return .nothing
        }
        return .text(text)
    }

    private static func sources(includeAllInstalled: Bool) -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        return TISCreateInputSourceList(filter, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    private static func string(of source: TISInputSource, _ key: CFString) -> String? {
        TISGetInputSourceProperty(source, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        TISGetInputSourceProperty(source, key)
            .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? false
    }
}
