// SPDX-License-Identifier: GPL-3.0-or-later

import Carbon
import PerekeyCore
import Testing
@testable import PerekeyInput

// Read-only: none of these tests selects a layout, so the user's current one stays.
@MainActor
struct InputSourcesTests {
    @Test func enabledLayoutsContainCurrentKeyboardLayout() throws {
        let layouts = LayoutReader.enabledLayouts()
        #expect(!layouts.isEmpty)
        let current = try #require(LayoutReader.currentLayoutID())
        // The current source may be an input method, which is not a keyboard layout.
        if let source = LayoutReader.anySource(current),
           LayoutReader.string(of: source, kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String)
        {
            #expect(layouts.contains { $0.id == current })
        }
    }

    @Test func inputSourcesMirrorsReader() {
        let sources = InputSources()
        #expect(sources.layouts.map(\.id) == LayoutReader.enabledLayouts().map(\.id))
        #expect(sources.currentLayout == LayoutReader.currentLayoutID())
        for layout in sources.layouts {
            #expect(!sources.name(of: layout.id).isEmpty)
            #expect(sources.indicator(of: layout.id).count >= 1)
        }
        #expect(sources.select("com.example.no-such-layout") == false)
    }

    @Test func abcToRussian() throws {
        let abc = try #require(LayoutReader.installedLayout("com.apple.keylayout.ABC"))
        let russian = try #require(LayoutReader.installedLayout("com.apple.keylayout.Russian"))
        #expect(russian.convert("ghbdtn", from: abc) == "привет")
    }

    @Test func everyInstalledSourceIsReadWithoutCrash() throws {
        let list = try #require(TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource])
        #expect(!list.isEmpty)
        for source in list {
            let hasTable = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) != nil
            let map = LayoutReader.layoutMap(of: source)
            if !hasTable { #expect(map == nil) }
        }
    }
}
