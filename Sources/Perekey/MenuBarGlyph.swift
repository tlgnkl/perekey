// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyCore
import SwiftUI

/// The Perekey mark for the menu bar: the signature strip as a template outline
/// with the hatch inside, no language. A paused Perekey draws it at 40%; with
/// automatic switching off a slash crosses it. Black on clear: the system
/// tints a template image to the menu bar.
enum MenuBarMark {
    static func image(held: Bool, struck: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let strip = NSBezierPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.75), xRadius: 5.25, yRadius: 5.25)
            let alpha: CGFloat = held ? 0.4 : 1
            NSColor.black.withAlphaComponent(alpha).setStroke()
            strip.lineWidth = 1.5
            strip.stroke()
            NSGraphicsContext.saveGraphicsState()
            strip.addClip()
            let hatch = NSBezierPath()
            var x: CGFloat = -4
            while x < rect.width {
                hatch.move(to: NSPoint(x: x, y: 0))
                hatch.line(to: NSPoint(x: x + rect.height, y: rect.height))
                x += 4.5
            }
            hatch.lineWidth = 1.1
            NSColor.black.withAlphaComponent(alpha * 0.6).setStroke()
            hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()
            if struck {
                // A slash with a clear gap on both sides, so it reads on the hatch.
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3.5, y: 1))
                slash.line(to: NSPoint(x: rect.width - 3.5, y: rect.height - 1))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .clear
                slash.lineWidth = 4.5
                slash.lineCapStyle = .round
                slash.stroke()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.black.setStroke()
                slash.lineWidth = 1.5
                slash.lineCapStyle = .round
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A line from the bottom left to the top right: "automatic switching is off"
/// on an icon that has no letters to strike.
private struct Slash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// The menu bar item in the three styles without a capsule: layout letters, the
/// system's icon for the layout, or the Perekey mark. All follow the menu bar's
/// color (the primary foreground), like the system's own icons.
struct MenuBarGlyph: View {
    /// `.letters`, `.system` or `.mark`; `.capsule` is `CapsuleView`.
    let style: MenuBarIconStyle
    let model: CapsuleModel
    /// The system's icon for the layout, for `.system`; without it the letters show.
    var icon: NSImage?

    var body: some View {
        HStack(spacing: 3) {
            if model.noAccess {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5, weight: .bold))
            }
            if style != .mark, let reason = model.reason {
                Image(systemName: reason.symbol).font(.system(size: 10.5, weight: .bold))
            }
            content
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 2)
        .frame(minHeight: 18)
        .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .mark:
            Image(nsImage: MenuBarMark.image(held: model.reason != nil, struck: model.struck))
                .renderingMode(.template)
        case .system:
            if let icon {
                Image(nsImage: icon)
                    .renderingMode(icon.isTemplate ? .template : .original)
                    .overlay { if model.struck { Slash().stroke(lineWidth: 1.5).padding(1) } }
            } else {
                letters
            }
        case .letters, .capsule:
            letters
        }
    }

    private var letters: some View {
        Text(model.code)
            .font(.system(size: 13, weight: .semibold))
            .strikethrough(model.struck)
            .opacity(model.struck ? 0.7 : 1)
    }
}

/// Whether the system's own input menu shows in the menu bar
/// (`com.apple.TextInputMenu`, `visible`). Perekey only reads it. Read again
/// whenever Settings shows and the app becomes active, since the user flips it
/// in System Settings.
@MainActor
@Observable
final class SystemInputMenu {
    static let shared = SystemInputMenu()

    /// `nil` when the system has not said.
    private(set) var visible: Bool?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init() {
        visible = Self.read()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// A fixed answer, for snapshots.
    init(preview: Bool?) {
        visible = preview
    }

    func refresh() {
        guard observer != nil else { return }
        visible = Self.read()
    }

    private static func read() -> Bool? {
        let domain = "com.apple.TextInputMenu" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue("visible" as CFString, domain) else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
