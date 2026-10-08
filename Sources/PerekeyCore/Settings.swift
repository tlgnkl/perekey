// SPDX-License-Identifier: GPL-3.0-or-later

/// An immutable snapshot of the settings the input logic needs.
///
/// The app owns the editable settings. It sends a fresh snapshot to the event
/// tap thread as a whole, so the tap never reads half-updated state.
public struct Settings: Hashable, Sendable, Codable {
    public var hotkeys: [HotkeyBinding]
    /// Automatic switching while typing. ⇧+⇧ toggles it.
    public var autoswitch: Bool
    /// How long user input is held back after a retype at most, in seconds,
    /// when the layout change notification does not arrive.
    public var fenceTimeout: Double

    public init(
        hotkeys: [HotkeyBinding] = HotkeyPreset.default.hotkeys,
        autoswitch: Bool = true,
        fenceTimeout: Double = 0.3
    ) {
        self.hotkeys = hotkeys
        self.autoswitch = autoswitch
        self.fenceTimeout = fenceTimeout
    }
}
