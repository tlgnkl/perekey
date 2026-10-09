// SPDX-License-Identifier: GPL-3.0-or-later

import Carbon
import Foundation
import Observation
import PerekeyCore

/// The enabled keyboard layouts and the selected one, kept in sync with the system.
///
/// Text Input Sources are not thread-safe (`TextInputSources.h`), so this class
/// lives on the main thread. The `LayoutMap` values it publishes are immutable;
/// `onLayoutsChanged` hands them over for the tap thread.
@MainActor
@Observable
public final class InputSources {
    /// Enabled, select-capable keyboard layouts in system order.
    public private(set) var layouts: [LayoutMap] = []

    /// The selected keyboard input source. It can be an input method that is not
    /// in `layouts`; the core treats such IDs as "do not retype".
    public private(set) var currentLayout: LayoutID?

    @ObservationIgnored public var onLayoutsChanged: (@MainActor ([LayoutMap]) -> Void)?
    @ObservationIgnored public var onCurrentChanged: (@MainActor (LayoutID) -> Void)?

    /// Refs for `TISSelectInputSource`, rebuilt together with `layouts`.
    @ObservationIgnored private var sourcesByID: [LayoutID: TISInputSource] = [:]
    /// The keyboard type the maps were built with: `UCKeyTranslate` output depends on it.
    @ObservationIgnored private var builtKeyboardType: UInt8 = 0
    @ObservationIgnored private var observer: NotificationObserver?

    #if DEBUG
    /// Snapshot helper: these layouts, no system observers.
    @ObservationIgnored private var previewNames: [LayoutID: String] = [:]

    public init(preview layouts: [LayoutMap], current: LayoutID?, names: [LayoutID: String]) {
        self.layouts = layouts
        currentLayout = current
        previewNames = names
    }
    #endif

    public init() {
        reload()
        currentLayout = LayoutReader.currentLayoutID()
        observer = NotificationObserver(
            selectedChanged: { [weak self] in self?.selectedSourceChanged() },
            enabledChanged: { [weak self] in self?.enabledSetChanged() }
        )
    }

    /// Selects `id`; never toggles. Returns false for an unknown ID or when the system refuses.
    /// `currentLayout` follows through the system notification, not here.
    @discardableResult
    public func select(_ id: LayoutID) -> Bool {
        guard let source = sourcesByID[id] else { return false }
        return TISSelectInputSource(source) == noErr
    }

    /// The localized name, e.g. "Russian". Falls back to the ID for unknown sources.
    public func name(of id: LayoutID) -> String {
        #if DEBUG
        if let name = previewNames[id] { return name }
        #endif
        return source(for: id).flatMap { LayoutReader.string(of: $0, kTISPropertyLocalizedName) } ?? id.rawValue
    }

    /// A short menu bar code: the language ("EN", "RU"), else the first two letters of the name.
    public func indicator(of id: LayoutID) -> String {
        let language = layouts.first { $0.id == id }?.language
            ?? source(for: id).flatMap { LayoutReader.languages(of: $0).first }
        if let code = language?.split(separator: "-").first, code.count >= 2 {
            return code.uppercased()
        }
        return String(name(of: id).prefix(2)).uppercased()
    }

    private func source(for id: LayoutID) -> TISInputSource? {
        sourcesByID[id] ?? LayoutReader.anySource(id)
    }

    private func reload() {
        let enabled = LayoutReader.enabledSources()
        builtKeyboardType = LMGetKbdType()
        sourcesByID = Dictionary(enabled.map { ($0.map.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        layouts = enabled.map(\.map)
    }

    private func enabledSetChanged() {
        reload()
        onLayoutsChanged?(layouts)
        selectedSourceChanged()
    }

    private func selectedSourceChanged() {
        if LMGetKbdType() != builtKeyboardType {
            reload()
            onLayoutsChanged?(layouts)
        }
        guard let id = LayoutReader.currentLayoutID(), id != currentLayout else { return }
        currentLayout = id
        onCurrentChanged?(id)
    }
}

/// Subscribes to the two TIS notifications, which the system posts as distributed ones.
///
/// `.deliverImmediately` matters: a menu bar app is almost never active, and
/// AppKit holds notifications back from inactive apps otherwise. That needs the
/// selector-based API, hence an `NSObject`. The observer unregisters in its own
/// `deinit`, because a nonisolated `deinit` of `InputSources` cannot touch its state.
private final class NotificationObserver: NSObject, @unchecked Sendable {
    private let selectedChanged: @MainActor () -> Void
    private let enabledChanged: @MainActor () -> Void

    @MainActor
    init(selectedChanged: @escaping @MainActor () -> Void, enabledChanged: @escaping @MainActor () -> Void) {
        self.selectedChanged = selectedChanged
        self.enabledChanged = enabledChanged
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(selected), name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                           object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(enabled), name: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                           object: nil, suspensionBehavior: .deliverImmediately)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // Distributed notifications arrive on the main run loop.
    @objc private func selected(_: Notification) {
        MainActor.assumeIsolated { selectedChanged() }
    }

    @objc private func enabled(_: Notification) {
        MainActor.assumeIsolated { enabledChanged() }
    }
}
