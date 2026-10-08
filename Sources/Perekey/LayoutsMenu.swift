// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyInput
import SwiftUI

/// The enabled layouts with a checkmark on the selected one; a click selects.
struct LayoutsMenu: View {
    let sources: InputSources

    var body: some View {
        ForEach(sources.layouts, id: \.id) { layout in
            Toggle(sources.name(of: layout.id), isOn: Binding(
                get: { sources.currentLayout == layout.id },
                set: { _ in sources.select(layout.id) }
            ))
        }
    }
}
