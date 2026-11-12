// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// What the real machine does for the bench: the platform half of `AppSystem`, in `perekey-e2e`
/// (`CGEvent`, Accessibility, the input sources). A class: it holds the app and its field.
public protocol AppDriver: AnyObject {
    /// Empties the field, chooses the layout (an input source id) and waits until the system says it is
    /// in force.
    func prepare(start: String) throws
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

    /// Plays the events of a case in the app. `input` is checked before every event: a refusal ends
    /// the case with no further key.
    public func run(_ item: EvalCase, events: [TypedEvent], library: LayoutLibrary, input: inout InputGuard, app: String)
        throws -> RunResult
    {
        guard let start = library[item.start] else { throw EvalError.input("\(item.id): unknown layout \(item.start)") }
        try input.check(app: app)
        try driver.prepare(start: start.id.rawValue)
        // `prepare` posts a key of its own (Escape): it resets the idle time like any other of ours.
        input.posted()
        guard let first = events.first?.time else {
            return RunResult(text: try driver.readText(), layout: LayoutID(driver.currentLayout()))
        }
        let began = driver.now()
        for typed in events {
            guard let actions = AppActions.actions(for: typed.event) else { throw Failure.unsupportedEvent(item.id) }
            let wait = began + (typed.time - first) - driver.now()
            if wait > 0 { driver.sleep(wait) }
            try input.check(app: app)
            for action in actions {
                try driver.perform(action)
                input.posted()
            }
        }
        if case let .idle(seconds) = events.last?.event { driver.sleep(seconds) }
        driver.sleep(options.settleSeconds)
        return RunResult(text: try driver.readText(), layout: LayoutID(driver.currentLayout()))
    }
}
