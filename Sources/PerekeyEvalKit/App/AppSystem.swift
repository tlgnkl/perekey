// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// What the real machine does for the bench: the platform half of `AppSystem`, in `perekey-e2e`
/// (`CGEvent`, Accessibility, the input sources). A class: it holds the app and its field.
public protocol AppDriver: AnyObject {
    /// Empties the field, chooses the layout (an input source id) and waits until the system says it is
    /// in force. `beforePost` is the guard: the driver calls it before each key it posts itself (Escape)
    /// and before it chooses the layout, and a refusal ends `prepare` at once.
    func prepare(start: String, beforePost: () throws -> Void) throws
    func perform(_ action: AppAction) throws
    /// The text of the field, through Accessibility.
    func readText() throws -> String
    /// The id of the layout in force.
    func currentLayout() -> String
    /// A clock that never goes back, in seconds.
    func now() -> Double
    func sleep(_ seconds: Double)
}

/// Perekey in a real app: the same events of the typist as `MachineSystem` gets, posted as `CGEvent`s
/// at the pace of the case, and the text of the field read back (docs/eval.md, «Настоящая программа»).
/// It does not conform to `TypingSystem`: it needs a driver, not a `CaseSetup` alone.
public struct AppSystem {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupportedEvent(String)

        public var description: String {
            switch self {
            case let .unsupportedEvent(id): "\(id): an event the app cannot be given; the case is not played"
            }
        }
    }

    public struct Options: Sendable {
        /// After the last event of the case (which already ends in the pause of the typist): the app
        /// and Perekey finish their last retype before the text is read.
        public var settleSeconds = 0.5

        public init() {}
    }

    public let driver: any AppDriver
    public let options: Options

    public init(driver: any AppDriver, options: Options = Options()) {
        self.driver = driver
        self.options = options
    }

    /// Plays the events of a case in the app. `input` is checked before every key and every choice of
    /// layout, inside `prepare` too: a refusal ends the case with no further key. A modifier the case
    /// holds down is let go after a refusal, but only if the guard lets the bench post that key now.
    public func run(_ item: EvalCase, events: [TypedEvent], library: LayoutLibrary, input: InputGuard, app: String)
        throws -> RunResult
    {
        guard let start = library[item.start] else { throw EvalError.input("\(item.id): unknown layout \(item.start)") }
        try input.check(app: app)
        try driver.prepare(start: start.id.rawValue) { try input.beforePost(app: app) }
        guard let first = events.first?.time else {
            return RunResult(text: try driver.readText(), layout: LayoutID(driver.currentLayout()))
        }
        var held = HeldModifiers()
        let began = driver.now()
        do {
            for typed in events {
                guard let actions = AppActions.actions(for: typed.event) else { throw Failure.unsupportedEvent(item.id) }
                let wait = began + (typed.time - first) - driver.now()
                if wait > 0 { driver.sleep(wait) }
                for action in actions {
                    try input.beforePost(app: app)
                    try driver.perform(action)
                    held.apply(action)
                }
            }
        } catch {
            releaseHeld(held, input: input, app: app)
            throw error
        }
        if case let .idle(seconds) = events.last?.event { driver.sleep(seconds) }
        driver.sleep(options.settleSeconds)
        return RunResult(text: try driver.readText(), layout: LayoutID(driver.currentLayout()))
    }

    /// After an error: the modifiers still down come up, one key each, and only while the guard lets the
    /// bench post. When it does not (the screen is locked, a person is typing), nothing is sent.
    private func releaseHeld(_ held: HeldModifiers, input: InputGuard, app: String) {
        for code in held.codes {
            guard (try? input.beforePost(app: app)) != nil else { return }
            try? driver.perform(.modifier(code: code, flags: 0))
        }
    }
}

/// The modifier keys the bench has put down and not yet let go, from the `.modifier` actions it posted.
struct HeldModifiers {
    private(set) var codes: [UInt16] = []
    private var flags: UInt64 = 0

    mutating func apply(_ action: AppAction) {
        guard case let .modifier(code, now) = action else { return }
        if now & ~flags != 0 {
            if !codes.contains(code) { codes.append(code) }
        } else if now == 0 {
            codes = []
        } else {
            codes.removeAll { $0 == code }
        }
        flags = now
    }
}
