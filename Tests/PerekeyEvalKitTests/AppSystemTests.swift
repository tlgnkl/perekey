// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyDesk
import Testing
@testable import PerekeyEvalKit

struct FakeFailure: Error, CustomStringConvertible { var description: String }

/// A machine that is only a script: what the guard reads, what the driver was told to do.
final class FakeMachine: AppDriver, AppPlatform, @unchecked Sendable {
    var locked = false
    var idle: Double? = 600
    var front: String? = "com.apple.TextEdit"
    var clock = 1000.0
    /// What every action does to the guard's readings: the bench's own key sets the idle time to zero.
    var actions: [AppAction] = []
    var prepared: [String] = []
    var drivers = 0
    var text = ""
    var layout = "com.apple.keylayout.ABC"
    var enabled: Set<String>? = ["com.apple.keylayout.ABC", "com.apple.keylayout.Russian"]
    /// Runs after this many actions: lets a test lock the screen or touch the keyboard in the middle of a case.
    var after: (count: Int, run: () -> Void)?
    var sleeps: [Double] = []
    /// Runs when the n-th case is prepared.
    var onPrepare: ((Int) -> Void)?
    var lastOwn: Double?
    /// The clock at which a person moved the mouse; nil: nobody did.
    var mouseTouched: Double?
    /// The clock at which a person pressed a key, as the listen-only tap sees it; nil: nobody did.
    var humanKeyAt: Double?
    /// Whether the machine has the tap (Input Monitoring given).
    var watched = true
    /// The front app reads wrong at this one reading (counted from 1 over `checks`), and right again after it.
    var wrongFrontOnCall: Int?
    var checks = 0
    /// How many of the guarded steps of `prepare` went through.
    var prepareSteps = 0

    var probe: InputGuard.Probe {
        InputGuard.Probe(
            screenLocked: { self.locked },
            idleSeconds: { self.lastOwn.map { min(self.idle ?? .infinity, self.clock - $0) } ?? self.idle },
            frontmostApp: {
                self.checks += 1
                return self.checks == self.wrongFrontOnCall ? "com.apple.Terminal" : self.front
            },
            now: { self.clock },
            // A mouse nobody touched has been still longer than the run has lasted.
            mouseIdleSeconds: { self.mouseTouched.map { self.clock - $0 } ?? 600 + self.clock - 1000 },
            lastHumanKey: watched ? { self.humanKeyAt } : nil
        )
    }

    func enabledLayouts() -> Set<String>? { enabled }

    func makeDriver(bundle: String) throws -> any AppDriver {
        drivers += 1
        return self
    }

    func prepare(start: String, beforePost: () throws -> Void) throws {
        // As the real one: the guard before each of the two keys of Escape and before the choice of layout.
        try beforePost()
        prepareSteps += 1
        lastOwn = clock
        try beforePost()
        prepareSteps += 1
        try beforePost()
        prepareSteps += 1
        prepared.append(start)
        layout = start
        onPrepare?(prepared.count)
    }

    /// The n-th action fails with an error that is not the guard's.
    var failOnAction: Int?

    func perform(_ action: AppAction) throws {
        if failOnAction == actions.count + 1 { throw FakeFailure(description: "the app did not answer") }
        actions.append(action)
        lastOwn = clock
        if let after, actions.count == after.count { after.run() }
    }

    func readText() throws -> String { text }
    func currentLayout() -> String { layout }
    func now() -> Double { clock }

    func sleep(_ seconds: Double) {
        sleeps.append(seconds)
        clock += seconds
    }
}

@Suite struct InputGuardTests {
    static let app = "com.apple.TextEdit"

    func makeGuard(_ machine: FakeMachine) -> InputGuard { InputGuard(probe: machine.probe) }

    @Test func aLockedScreenStopsTheRunAndNothingIsPosted() throws {
        let machine = FakeMachine()
        machine.locked = true
        let input = makeGuard(machine)
        #expect(throws: InputGuard.Refusal.screenLocked) { try input.check(app: Self.app) }
        #expect(InputGuard.Refusal.screenLocked.exitCode == 3)
        #expect(machine.actions.isEmpty)
    }

    @Test func aPersonAtTheKeyboardStopsTheRun() throws {
        let machine = FakeMachine()
        machine.idle = 9.9
        let input = makeGuard(machine)
        #expect(throws: InputGuard.Refusal.humanActive(idle: 9.9)) { try input.check(app: Self.app) }
        #expect(InputGuard.Refusal.humanActive(idle: 9.9).exitCode == 4)
        machine.idle = 10.5
        try input.check(app: Self.app)
    }

    @Test func aMachineThatDoesNotSayHowLongItIsIdleIsNotTrusted() throws {
        let machine = FakeMachine()
        machine.idle = nil
        let input = makeGuard(machine)
        #expect(throws: InputGuard.Refusal.idleUnknown) { try input.check(app: Self.app) }
    }

    @Test func theBenchsOwnKeysAreNotAPerson() throws {
        let machine = FakeMachine()
        let input = makeGuard(machine)
        try input.beforePost(app: Self.app)
        // The key just posted makes the idle time zero; a person did not do it.
        try machine.perform(.keyDown(code: 0, flags: 0))
        machine.clock += 0.05
        try input.beforePost(app: Self.app)
        machine.clock += 3
        try input.beforePost(app: Self.app)
    }

    @Test func aPersonAfterTheBenchsLastKeyIsSeen() throws {
        let machine = FakeMachine()
        machine.watched = false
        let input = makeGuard(machine)
        try input.beforePost(app: Self.app)
        try machine.perform(.keyDown(code: 0, flags: 0))
        machine.clock += 5
        // Someone pressed a key 1 s ago: the idle time is 1 s, the last key of the bench was 5 s ago.
        machine.idle = 1
        #expect(throws: InputGuard.Refusal.humanActive(idle: 1)) { try input.check(app: Self.app) }
    }

    @Test func withoutATapAKeyBetweenFastKeysOfTheBenchIsNotSeen() throws {
        // The limit of the fallback, said in docs/eval.md: a key every 0.1 s keeps the idle time under
        // the slack, so a person's key among them changes nothing the guard reads.
        let machine = FakeMachine()
        machine.watched = false
        let input = makeGuard(machine)
        for _ in 0..<20 {
            try input.beforePost(app: Self.app)
            try machine.perform(.keyDown(code: 0, flags: 0))
            machine.clock += 0.1
        }
        machine.idle = 0.05
        try input.beforePost(app: Self.app)
    }

    @Test func theMouseIsSeenAtAnyPaceWithNoSlack() throws {
        let machine = FakeMachine()
        machine.watched = false
        let input = makeGuard(machine)
        try input.beforePost(app: Self.app)
        for _ in 0..<5 {
            machine.clock += 0.05
            try input.beforePost(app: Self.app)
            try machine.perform(.keyDown(code: 0, flags: 0))
        }
        machine.mouseTouched = machine.clock
        machine.clock += 0.05
        #expect(throws: InputGuard.Refusal.self) { try input.beforePost(app: Self.app) }
    }

    @Test func aKeyOfAPersonSeenByTheTapStopsTheRunAtAnyPace() throws {
        let machine = FakeMachine()
        let input = makeGuard(machine)
        for _ in 0..<5 {
            try input.beforePost(app: Self.app)
            try machine.perform(.keyDown(code: 0, flags: 0))
            machine.clock += 0.05
        }
        machine.humanKeyAt = machine.clock - 0.02
        #expect(throws: InputGuard.Refusal.self) { try input.check(app: Self.app) }
    }

    @Test func aKeyOfAPersonBeforeTheRunIsLeftToTheQuietCheck() throws {
        let machine = FakeMachine()
        machine.humanKeyAt = machine.clock - 30
        let input = makeGuard(machine)
        try input.beforePost(app: Self.app)
        machine.clock += 1
        try input.beforePost(app: Self.app)
    }

    @Test func anotherAppInFrontStopsTheRun() throws {
        let machine = FakeMachine()
        machine.front = "com.apple.Terminal"
        let input = makeGuard(machine)
        let refusal = InputGuard.Refusal.wrongApp(expected: Self.app, actual: "com.apple.Terminal")
        #expect(throws: refusal) { try input.check(app: Self.app) }
        #expect(refusal.exitCode == 5)
    }

    @Test func theScreenIsReadBeforeEveryOtherThing() throws {
        // Locked and a person active at once: the lock is what is said.
        let machine = FakeMachine()
        machine.locked = true
        machine.idle = 0
        machine.front = nil
        let input = makeGuard(machine)
        #expect(throws: InputGuard.Refusal.screenLocked) { try input.check(app: Self.app) }
    }
}

@Suite struct AppActionsTests {
    @Test func aKeyIsPostedWithItsFlags() {
        #expect(AppActions.actions(for: .keyDown(keyCode: 6, flags: EventFlags.shift)) == [.keyDown(code: 6, flags: EventFlags.shift)])
        #expect(AppActions.actions(for: .flags(keyCode: 56, flags: EventFlags.shift)) == [.modifier(code: 56, flags: EventFlags.shift)])
        #expect(AppActions.actions(for: .userLayout("com.apple.keylayout.Russian")) == [.layout("com.apple.keylayout.Russian")])
        #expect(AppActions.actions(for: .idle(seconds: 2)) == [])
    }

    @Test func anArrowCarriesTheFlagsAPersonsArrowDoes() {
        let actions = AppActions.actions(for: .keyDown(keyCode: KeyCode.leftArrow, flags: 0))
        #expect(actions == [.keyDown(code: KeyCode.leftArrow, flags: AppActions.arrowFlags)])
    }

    @Test func aClickMovesTheCaretWithKeys() {
        let start = AppActions.actions(for: .click(.start))!
        #expect(start == [.modifier(code: 55, flags: EventFlags.command),
                          .keyDown(code: KeyCode.upArrow, flags: EventFlags.command | AppActions.arrowFlags),
                          .keyUp(code: KeyCode.upArrow, flags: EventFlags.command | AppActions.arrowFlags),
                          .modifier(code: 55, flags: 0)])
        let two = AppActions.actions(for: .click(.position(2)))!
        #expect(two.count == 4 + 4)
        #expect(two.suffix(4).allSatisfy {
            if case let .keyDown(code, _) = $0 { code == KeyCode.rightArrow } else if case let .keyUp(code, _) = $0 { code == KeyCode.rightArrow } else { false }
        })
        #expect(AppActions.actions(for: .click(.end))!.contains(.keyDown(code: KeyCode.downArrow, flags: EventFlags.command | AppActions.arrowFlags)))
    }

    @Test func aSelectionIsShiftAndLeftArrows() {
        let actions = AppActions.actions(for: .select(chars: 3))!
        #expect(actions.first == .modifier(code: 56, flags: EventFlags.shift))
        #expect(actions.last == .modifier(code: 56, flags: 0))
        #expect(actions.filter { if case .keyDown = $0 { true } else { false } }.count == 3)
    }

    @Test func whatNoKeyCanDoHasNoActions() {
        #expect(AppActions.actions(for: .focus(Focus(bundleID: "com.apple.Terminal"))) == nil)
        #expect(AppActions.actions(for: .mode(.off)) == nil)
        #expect(AppActions.actions(for: .secureInput(true)) == nil)
        #expect(AppActions.actions(for: .capsLock(true)) == nil)
        #expect(AppActions.actions(for: .undoButton) == nil)
        #expect(AppActions.actions(for: .click(.hint)) == nil)
    }

    @Test func everyEventOfASupportedCaseHasActions() throws {
        // Support and translation agree: a case `AppSupport` lets through never meets an event without actions.
        let items = try CaseCodec.read(file: Repo.path("eval/cases/flow.basics.jsonl"))
            + CaseCodec.read(file: Repo.path("eval/cases/incidents.jsonl"))
        var played = 0
        for item in items where AppSupport.unsupported(item, bundle: "com.apple.TextEdit", enabled: nil, library: Repo.library) == nil {
            played += 1
            for typed in try Typist().events(for: item, layouts: Repo.library) {
                #expect(AppActions.actions(for: typed.event) != nil, "\(item.id)")
            }
        }
        #expect(played > 0)
    }
}

@Suite struct AppSupportTests {
    func reason(_ item: EvalCase, enabled: Set<String>? = nil) -> String? {
        AppSupport.unsupported(item, bundle: "com.apple.TextEdit", enabled: enabled, library: Repo.library)
    }

    @Test func aPlainCaseIsPlayed() {
        #expect(reason(Cases.make([.type("привет ", on: "Russian")], want: "привет")) == nil)
    }

    @Test(arguments: [
        ("focus", [Step.focus(.init(app: "com.apple.Terminal"))]),
        ("mode", [Step.mode(.off)]),
        ("secureInput", [Step.secureInput(true)]),
        ("capsLock", [Step.capsLock(true)]),
        ("undo", [Step.undo(.button)]),
        ("hint", [Step.click(.hint)]),
    ])
    func aStepTheAppCannotBeGivenIsCounted(_ expected: String, _ steps: [Step]) {
        #expect(reason(Cases.make(steps + [.type("привет ", on: "Russian")], want: "привет")) == expected)
    }

    @Test func theEnvironmentOfTheCaseIsTheAppsOwn() {
        let script: [Step] = [.type("привет ", on: "Russian")]
        #expect(reason(Cases.make(script, want: "привет", env: Env(app: "com.apple.Terminal"))) == "app")
        #expect(reason(Cases.make(script, want: "привет", env: Env(settings: "all"))) == "settings")
        #expect(reason(Cases.make(script, want: "привет", env: Env(mode: .manualOnly))) == "mode")
        #expect(reason(Cases.make(script, want: "привет", env: Env(secureInput: true))) == "secureInput")
        #expect(reason(Cases.make(script, want: "привет", env: Env(exceptions: ["привет"]))) == "exceptions")
        #expect(reason(Cases.make(script, want: "привет", env: Env(prior: ["ru": 3]))) == "prior")
        #expect(reason(Cases.make(script, want: "привет", env: Env(pace: .burst, lag: 3))) == nil)
    }

    @Test func theAppDoesNotTellHowManyCorrectionsItMade() {
        let script: [Step] = [.type("привет ", on: "Russian")]
        #expect(reason(Cases.make(script, want: "привет", scoring: .case, checks: [.corrections(1)])) == "checks")
        #expect(reason(Cases.make(script, want: "привет", scoring: .case, checks: [.undone(0)])) == "checks")
        #expect(reason(Cases.make(script, want: "привет", scoring: .case, checks: [.layout("Russian")])) == nil)
    }

    @Test func theLayoutsOfTheCaseAreTheOnesTheSystemHasOn() {
        let item = Cases.make([.type("привет ", on: "Russian")], want: "привет")
        #expect(reason(item, enabled: ["com.apple.keylayout.ABC", "com.apple.keylayout.Russian"]) == nil)
        #expect(reason(item, enabled: ["com.apple.keylayout.ABC"]) == "layouts")
        #expect(reason(item, enabled: ["com.apple.keylayout.ABC", "com.apple.keylayout.Russian", "com.apple.keylayout.Ukrainian"]) == "layouts")
    }
}

@Suite struct AppSystemTests {
    let app = "com.apple.TextEdit"

    func input(_ machine: FakeMachine) -> InputGuard { InputGuard(probe: machine.probe) }

    func item() -> EvalCase { Cases.make([.type("привет ", on: "Russian")], want: "привет") }

    @Test func theEventsAreGivenToTheAppAtTheirTimes() throws {
        let machine = FakeMachine()
        machine.text = "привет "
        let guardian = input(machine)
        let events = try Typist().events(for: item(), layouts: Repo.library)
        let result = try AppSystem(driver: machine).run(item(), events: events, library: Repo.library, input: guardian, app: app)
        #expect(result.text == "привет ")
        #expect(machine.prepared == ["com.apple.keylayout.ABC"])
        // Seven keys, each with a key down and a key up.
        #expect(machine.actions.count == 14)
        // The pauses add up to the time of the case, the pause at its end (the last event) and the settling time.
        let total = machine.sleeps.reduce(0, +)
        let span = events.last!.time - events.first!.time
        #expect(abs(total - (span + Typist.Options().endPause + AppSystem.Options().settleSeconds)) < 1e-6)
    }

    @Test func aLockedScreenPostsNoKeyAndDoesNotTouchTheField() throws {
        let machine = FakeMachine()
        machine.locked = true
        let guardian = input(machine)
        let events = try Typist().events(for: item(), layouts: Repo.library)
        #expect(throws: InputGuard.Refusal.screenLocked) {
            try AppSystem(driver: machine).run(item(), events: events, library: Repo.library, input: guardian, app: app)
        }
        #expect(machine.actions.isEmpty)
        #expect(machine.prepared.isEmpty)
    }

    @Test func theScreenLockedInTheMiddleOfACaseStopsTheNextKey() throws {
        let machine = FakeMachine()
        machine.after = (3, { machine.locked = true })
        let guardian = input(machine)
        let events = try Typist().events(for: item(), layouts: Repo.library)
        #expect(throws: InputGuard.Refusal.screenLocked) {
            try AppSystem(driver: machine).run(item(), events: events, library: Repo.library, input: guardian, app: app)
        }
        // The key down and up of the event in hand are one event; the one after it is not posted.
        #expect(machine.actions.count <= 4)
    }

    @Test func aPersonTouchingTheKeyboardInTheMiddleStopsTheNextKey() throws {
        let machine = FakeMachine()
        machine.watched = false
        let item = Cases.make([.type("привет ", on: "Russian"), .wait(3), .type("мир ", on: "Russian")], want: "привет мир")
        let events = try Typist().events(for: item, layouts: Repo.library)
        // The person touches the mouse during the wait: the idle time falls under the time since the last key.
        machine.after = (14, { machine.idle = 0.1 })
        let guardian = input(machine)
        #expect(throws: InputGuard.Refusal.humanActive(idle: 0.1)) {
            try AppSystem(driver: machine).run(item, events: events, library: Repo.library, input: guardian, app: app)
        }
        #expect(machine.actions.count == 14)
    }

    /// Keys 50 ms apart: faster than the one a second the fallback sees.
    func fast() -> EvalCase {
        var item = Cases.make([.type("привет мир ", on: "Russian")], want: "привет мир")
        item.env = Env(pace: .burst)
        return item
    }

    @Test func aPersonPressingAKeyInTheMiddleOfAFastCaseStopsTheNextKey() throws {
        let machine = FakeMachine()
        let item = fast()
        let events = try Typist().events(for: item, layouts: Repo.library)
        machine.after = (10, { machine.humanKeyAt = machine.clock })
        let guardian = input(machine)
        #expect(throws: InputGuard.Refusal.self) {
            try AppSystem(driver: machine).run(item, events: events, library: Repo.library, input: guardian, app: app)
        }
        #expect(machine.actions.count == 10)
    }

    @Test func aMouseTouchedInTheMiddleOfAFastCaseStopsTheNextKey() throws {
        let machine = FakeMachine()
        machine.watched = false
        let item = fast()
        let events = try Typist().events(for: item, layouts: Repo.library)
        machine.after = (10, { machine.mouseTouched = machine.clock })
        let guardian = input(machine)
        #expect(throws: InputGuard.Refusal.self) {
            try AppSystem(driver: machine).run(item, events: events, library: Repo.library, input: guardian, app: app)
        }
        #expect(machine.actions.count == 10)
    }

    @Test func theGuardIsAskedBeforeEveryKeyOfAnEventAndInsidePrepare() throws {
        let machine = FakeMachine()
        // Three keys of prepare, then the keys of the case: the lock comes after the key down of an arrow, so
        // its key up (the second action of the same event) must not go out.
        let item = Cases.make([.type("привет ", on: "Russian"), .key(.left, n: 1, mods: nil)], want: "привет")
        let events = try Typist().events(for: item, layouts: Repo.library)
        machine.after = (15, { machine.locked = true })
        let guardian = input(machine)
        #expect(throws: InputGuard.Refusal.screenLocked) {
            try AppSystem(driver: machine).run(item, events: events, library: Repo.library, input: guardian, app: app)
        }
        #expect(machine.actions.count == 15)
    }

    @Test func aRefusalInsidePrepareStopsTheStepsThatFollowIt() throws {
        let machine = FakeMachine()
        // Readings of the front app: 1 the look before `prepare`, 2 and 3 the two keys of Escape, 4 the choice
        // of the layout. The fourth reads wrong.
        machine.wrongFrontOnCall = 4
        let guardian = input(machine)
        let events = try Typist().events(for: item(), layouts: Repo.library)
        #expect(throws: InputGuard.Refusal.wrongApp(expected: app, actual: "com.apple.Terminal")) {
            try AppSystem(driver: machine).run(item(), events: events, library: Repo.library, input: guardian, app: app)
        }
        #expect(machine.prepareSteps == 2)
        #expect(machine.prepared.isEmpty && machine.actions.isEmpty)
    }

    func selecting() -> EvalCase {
        Cases.make([.type("привет ", on: "Russian"), .select(3)], want: "привет")
    }

    /// The actions of a whole play of `selecting()` and the index of the one that puts Shift down.
    func shiftDownIndex(_ item: EvalCase, _ events: [TypedEvent]) throws -> Int {
        let dry = FakeMachine()
        _ = try AppSystem(driver: dry).run(item, events: events, library: Repo.library, input: input(dry), app: app)
        return dry.actions.firstIndex { if case let .modifier(_, flags) = $0 { flags != 0 } else { false } }!
    }

    @Test func aRefusalInTheMiddleOfASelectionLetsGoOfShiftWhenTheGuardLetsTheBenchPost() throws {
        let machine = FakeMachine()
        let item = selecting()
        let events = try Typist().events(for: item, layouts: Repo.library)
        let down = try shiftDownIndex(item, events)
        // Right after the key down of Shift a window comes in front for one reading and goes: the next
        // key is refused, the one after it would pass.
        machine.after = (down + 2, { machine.wrongFrontOnCall = machine.checks + 1 })
        let guardian = input(machine)
        #expect(throws: InputGuard.Refusal.self) {
            try AppSystem(driver: machine).run(item, events: events, library: Repo.library, input: guardian, app: app)
        }
        #expect(machine.actions.count == down + 3)
        #expect(machine.actions.last == .modifier(code: 56, flags: 0))
    }

    @Test func aRefusalInTheMiddleOfASelectionSendsNothingWhileTheGuardStaysShut() throws {
        let machine = FakeMachine()
        let item = selecting()
        let events = try Typist().events(for: item, layouts: Repo.library)
        let down = try shiftDownIndex(item, events)
        machine.after = (down + 2, { machine.locked = true })
        let guardian = input(machine)
        #expect(throws: InputGuard.Refusal.screenLocked) {
            try AppSystem(driver: machine).run(item, events: events, library: Repo.library, input: guardian, app: app)
        }
        // Shift is still down in the system, and the bench posts nothing more: the screen is locked.
        #expect(machine.actions.count == down + 2)
    }

    @Test func theFirstCaseNeedsAQuietKeyboard() throws {
        let machine = FakeMachine()
        machine.idle = 3
        let guardian = input(machine)
        let events = try Typist().events(for: item(), layouts: Repo.library)
        #expect(throws: InputGuard.Refusal.humanActive(idle: 3)) {
            try AppSystem(driver: machine).run(item(), events: events, library: Repo.library, input: guardian, app: app)
        }
        #expect(machine.actions.isEmpty)
    }
}

@Suite struct AppCommandTests {
    func temp(_ name: String) -> String {
        let path = NSTemporaryDirectory() + "perekey-app-\(UUID().uuidString)-\(name)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func run(_ arguments: [String], on machine: FakeMachine) -> (status: Int32, out: String, err: String) {
        let capture = EvalContext.Capture()
        let status = EvalContext.$capture.withValue(capture) {
            AppCommand.run(arguments + ["--layouts", Repo.path("eval/layouts")], platform: machine)
        }
        return (status, capture.stdout, capture.stderr)
    }

    func cases(_ items: [EvalCase], in directory: String) throws -> String {
        let path = directory + "/cases.jsonl"
        try CaseCodec.write(items).write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    var sample: [EvalCase] {
        [Cases.make([.type("привет ", on: "Russian")], want: "привет", suite: "flow.test"),
         Cases.make([.type("мир ", on: "Russian")], want: "мир", suite: "flow.test"),
         Cases.make([.mode(.off), .type("пока ", on: "Russian")], want: "пока", suite: "flow.test")]
    }

    @Test func aDryRunPostsNothingAndStartsNoDriver() throws {
        let directory = temp("dry")
        let file = try cases(sample, in: directory)
        let machine = FakeMachine()
        let result = run(["play", "--cases", file, "--dry-run"], on: machine)
        #expect(result.status == 0)
        #expect(result.out.contains("2 to play"))
        #expect(result.out.contains("1 not played (mode 1)"))
        #expect(result.out.contains("nothing was posted"))
        #expect(machine.drivers == 0)
        #expect(machine.actions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory + "/run"))
    }

    @Test func aDryRunOnALockedScreenSaysSoAndStillPostsNothing() throws {
        let file = try cases(sample, in: temp("drylocked"))
        let machine = FakeMachine()
        machine.locked = true
        let result = run(["play", "--cases", file, "--dry-run"], on: machine)
        #expect(result.status == 0)
        #expect(result.out.contains("the screen is locked"))
        #expect(machine.drivers == 0 && machine.actions.isEmpty)
    }

    @Test func aLockedScreenEndsTheRunWithItsOwnExitCodeBeforeTheFirstKey() throws {
        let directory = temp("locked")
        let file = try cases(sample, in: directory)
        let machine = FakeMachine()
        machine.locked = true
        let result = run(["play", "--cases", file, "--out", directory + "/run"], on: machine)
        #expect(result.status == 3)
        #expect(result.err.contains("the screen is locked"))
        #expect(machine.drivers == 0)
        #expect(machine.prepared.isEmpty)
        #expect(machine.actions.isEmpty)
    }

    @Test func aPersonAtTheKeyboardEndsTheRunWithItsOwnExitCode() throws {
        let directory = temp("person")
        let file = try cases(sample, in: directory)
        let machine = FakeMachine()
        machine.idle = 2
        let result = run(["play", "--cases", file, "--out", directory + "/run"], on: machine)
        #expect(result.status == 4)
        #expect(machine.actions.isEmpty)
    }

    @Test func aRunWritesTheFilesOfAnyRunAndTheTextOfEachCase() throws {
        let directory = temp("play")
        let items = sample
        let file = try cases(items, in: directory)
        let machine = FakeMachine()
        machine.text = "привет"
        let result = run(["play", "--cases", file, "--out", directory + "/run"], on: machine)
        #expect(result.status == 0, "\(result.err)")
        for name in ["run.json", "cases.tsv", "events.jsonl", "summary.json", "counts.tsv", "slices.json", "words.tsv", "app.json"] {
            #expect(FileManager.default.fileExists(atPath: directory + "/run/" + name), "\(name)")
        }
        let record = try AppRun.read(from: directory + "/run")
        #expect(record.app == "com.apple.TextEdit")
        #expect(record.skipped == ["mode": 1])
        #expect(record.played.count == 2)
        #expect(record.played.allSatisfy { $0.text == "привет" && $0.layout == "com.apple.keylayout.ABC" })
        #expect(record.aborted == nil)
        let run = try String(contentsOfFile: directory + "/run/run.json", encoding: .utf8)
        #expect(run.contains("\"system\" : \"app\""))
    }

    @Test func aRunThatStopsKeepsWhatItPlayedAndSaysWhyItStopped() throws {
        let directory = temp("partial")
        let file = try cases(sample, in: directory)
        let machine = FakeMachine()
        // The screen locks as the second case is prepared: its first key is not posted.
        machine.onPrepare = { if $0 == 2 { machine.locked = true } }
        let result = run(["play", "--cases", file, "--out", directory + "/run"], on: machine)
        #expect(result.status == 3)
        #expect(machine.actions.count == 14)
        let record = try AppRun.read(from: directory + "/run")
        #expect(record.played.count == 1)
        #expect(record.aborted?.contains("the screen is locked") == true)
        #expect(result.err.contains("stopped after 1 of 2 cases"))
    }

    @Test func anyErrorInTheMiddleKeepsWhatWasPlayedAndEndsWithItsOwnCode() throws {
        let directory = temp("broke")
        let file = try cases(sample, in: directory)
        let machine = FakeMachine()
        // The second case fails on its sixth key: the first case is played, the run stops.
        machine.failOnAction = 14 + 6
        let result = run(["play", "--cases", file, "--out", directory + "/run"], on: machine)
        #expect(result.status == 6)
        #expect(result.err.contains("the app did not answer"))
        #expect(result.err.contains("stopped after 1 of 2 cases"))
        let record = try AppRun.read(from: directory + "/run")
        #expect(record.played.count == 1)
        #expect(record.aborted?.contains("the app did not answer") == true)
        #expect(FileManager.default.fileExists(atPath: directory + "/run/run.json"))
    }

    @Test func theTestPartKeepsOnlyTheHashOfTheText() throws {
        var item = Cases.make([.type("привет ", on: "Russian")], want: "привет", suite: "flow.test")
        item.split = .test
        item = try item.identified()
        let directory = temp("test")
        let file = try cases([item], in: directory)
        let machine = FakeMachine()
        machine.text = "привет"
        #expect(run(["play", "--cases", file, "--out", directory + "/run"], on: machine).status == 0)
        let record = try AppRun.read(from: directory + "/run")
        #expect(record.played[0].text == nil)
        #expect(record.played[0].sha256 == Runner.sha256(Data("привет".utf8)))
        let revealed = temp("revealed")
        let again = FakeMachine()
        again.text = "привет"
        #expect(run(["play", "--cases", file, "--out", revealed + "/run", "--reveal-test"], on: again).status == 0)
        #expect(try AppRun.read(from: revealed + "/run").played[0].text == "привет")
    }

    @Test func anAppWithoutADriverAndAPersonalSetAreRefused() throws {
        let directory = temp("refuse")
        let file = try cases(sample, in: directory)
        let machine = FakeMachine()
        #expect(run(["play", "--cases", file, "--app", "Chrome", "--dry-run"], on: machine).status == 2)
        #expect(run(["play", "--cases", file], on: machine).status == 2)
        #expect(run(["play", "--cases", file, "--out", directory + "/run", "--limit", "0"], on: machine).status == 2)
        #expect(machine.actions.isEmpty)
    }

    @Test func limitTakesTheFirstCases() throws {
        let directory = temp("limit")
        let file = try cases(sample, in: directory)
        let machine = FakeMachine()
        let result = run(["play", "--cases", file, "--out", directory + "/run", "--limit", "1"], on: machine)
        #expect(result.status == 0)
        let record = try AppRun.read(from: directory + "/run")
        #expect(record.played.count == 1)
        // The cut case is counted under its own reason: 3 cases = 1 played + mode 1 + limit 1.
        #expect(record.skipped == ["mode": 1, "limit": 1])
        #expect(result.out.contains("3 cases: 1 to play, 2 not played (limit 1, mode 1)"), "\(result.out)")
    }
}

@Suite struct FidelityTests {
    func make(_ suite: String, _ count: Int, split: EvalCase.Split = .dev) throws -> [EvalCase] {
        try (0..<count).map { number in
            var item = Cases.make([.type("привет\(String(repeating: "а", count: number)) ", on: "Russian")],
                                  want: "привет\(String(repeating: "а", count: number))", suite: suite)
            item.split = split
            return try item.identified()
        }
    }

    @Test func theSetTakesAFixedNumberFromEachFlowSuiteAndTechRuso() throws {
        let items = try make("flow.a", 30) + make("flow.b", 25) + make("flow.c", 5) + make("tech.ruso", 130) + make("prose.uk", 50)
        let chosen = FidelitySet.select(items)
        let counts = Dictionary(grouping: chosen, by: \.suite).mapValues(\.count)
        #expect(counts == ["flow.a": 20, "flow.b": 20, "flow.c": 5, "tech.ruso": 100])
    }

    @Test func theChoiceDependsOnTheContentNotTheOrder() throws {
        let items = try make("flow.a", 40)
        let first = FidelitySet.select(items)
        let second = FidelitySet.select(items.reversed())
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.id) == FidelitySet.select(items).map(\.id))
    }

    /// A stub of a recorded run: the app agrees with the machine on all cases but two.
    func stub(_ items: [EvalCase], machine: [String: (text: String, layout: String)]) -> AppRun {
        var played: [AppRun.Played] = []
        for (index, item) in items.enumerated() {
            var text = machine[item.id]!.text
            var layout = machine[item.id]!.layout
            if index == 1 { text += "!" }
            if index == 2 { layout = "com.apple.keylayout.Russian" }
            played.append(AppRun.played(item, RunResult(text: text, layout: LayoutID(layout)), reveal: false))
        }
        return AppRun(app: "com.apple.TextEdit", skipped: ["hint": 2, "focus": 1], played: played)
    }

    @Test func theReportCountsTheCasesWhoseTextDiffers() throws {
        let items = try make("flow.a", 10)
        var machine: [String: (text: String, layout: String)] = [:]
        for item in items { machine[item.id] = ("привет", "com.apple.keylayout.ABC") }
        let report = FidelityReport(items: items, machine: machine, app: stub(items, machine: machine), reveal: false)
        #expect(report.played == 10)
        // One case differs in the text, one only in the layout: the second is listed and not counted.
        #expect(report.differingTexts == 1)
        #expect(report.differences.count == 2)
        #expect(abs(report.rate - 0.1) < 1e-9)
        #expect(report.bySuite.map(\.suite) == ["flow.a"])
        let text = report.render()
        #expect(text.contains("played 10, final text differs in 1 (10.00 %)"))
        #expect(text.contains("NOT taken"))
        #expect(text.contains("not played 3: focus 1, hint 2"))
        #expect(text.contains("layout only"))
        #expect(text.contains("\"привет!\""))
    }

    @Test func theAimIsOnePercent() throws {
        let items = try make("flow.a", 100)
        var machine: [String: (text: String, layout: String)] = [:]
        for item in items { machine[item.id] = ("привет", "com.apple.keylayout.ABC") }
        var run = stub(items, machine: machine)
        // Only the first case differs: 1 of 100.
        run.played = run.played.enumerated().map { index, played in
            var copy = played
            if index != 0 { copy.sha256 = Runner.sha256(Data("привет".utf8)); copy.text = "привет"; copy.layout = "com.apple.keylayout.ABC" }
            else { copy.sha256 = "0"; copy.text = "x" }
            return copy
        }
        let report = FidelityReport(items: items, machine: machine, app: run, reveal: false)
        #expect(report.differingTexts == 1)
        #expect(report.rate <= FidelityReport.aim)
        #expect(report.render().contains("taken") && !report.render().contains("NOT taken"))
    }

    @Test func theWordsOfTheTestPartAreHiddenUnlessRevealed() throws {
        let items = try make("flow.a", 2, split: .test)
        var machine: [String: (text: String, layout: String)] = [:]
        for item in items { machine[item.id] = ("секрет", "com.apple.keylayout.ABC") }
        var run = stub(items, machine: machine)
        run.played[1].sha256 = "other"
        let hidden = FidelityReport(items: items, machine: machine, app: run, reveal: false).render()
        #expect(!hidden.contains("секрет"))
        #expect(hidden.contains("words hidden"))
    }

    @Test func aRunStoppedEarlyIsSaidInTheReport() throws {
        let items = try make("flow.a", 2)
        var machine: [String: (text: String, layout: String)] = [:]
        for item in items { machine[item.id] = ("привет", "com.apple.keylayout.ABC") }
        var run = stub(items, machine: machine)
        run.aborted = "the screen is locked"
        #expect(FidelityReport(items: items, machine: machine, app: run, reveal: false).render()
            .contains("THE RUN STOPPED EARLY: the screen is locked"))
    }

    @Test func aRunThatPlayedNothingDoesNotTakeTheAim() throws {
        let items = try make("flow.a", 2)
        let run = AppRun(app: "com.apple.TextEdit", skipped: ["mode": 2], played: [])
        let text = FidelityReport(items: items, machine: [:], app: run, reveal: false).render()
        #expect(text.contains("NOT taken (nothing played)"))
        #expect(text.contains("played 0"))
    }

    @Test func aRunStoppedEarlyIsNeverTaken() throws {
        let items = try make("flow.a", 4)
        var machine: [String: (text: String, layout: String)] = [:]
        for item in items { machine[item.id] = ("привет", "com.apple.keylayout.ABC") }
        let played = items.prefix(2).map {
            AppRun.played($0, RunResult(text: "привет", layout: LayoutID("com.apple.keylayout.ABC")), reveal: false)
        }
        let early = AppRun(app: "com.apple.TextEdit", skipped: [:], played: Array(played), aborted: "the screen is locked")
        let report = FidelityReport(items: items, machine: machine, app: early, reveal: false)
        #expect(report.differingTexts == 0)
        let text = report.render()
        #expect(text.contains("incomplete"))
        #expect(!text.contains(": taken"))
        // Over the aim already, an early stop is still «not taken».
        var worse = early
        worse.played[0].sha256 = "other"
        #expect(FidelityReport(items: items, machine: machine, app: worse, reveal: false).render()
            .contains("NOT taken (the run is incomplete)"))
    }

    @Test func theCommandsBuildTheSetAndCompareARecordedRun() throws {
        let directory = NSTemporaryDirectory() + "perekey-fidelity-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let items = try make("flow.a", 25)
        let all = directory + "/all.jsonl"
        try CaseCodec.write(items).write(toFile: all, atomically: true, encoding: .utf8)
        let layouts = ["--layouts", Repo.path("eval/layouts")]
        let capture = EvalContext.Capture()
        let built = EvalContext.$capture.withValue(capture) {
            EvalCommands.run(["cases", "fidelity", all, "--out", directory + "/fidelity.jsonl"] + layouts)
        }
        #expect(built == 0)
        #expect(capture.stdout.contains("20 cases: flow.a 20"))
        let chosen = try CaseCodec.read(file: directory + "/fidelity.jsonl")
        #expect(chosen.count == 20)

        // The recorded run: the app typed what the oracle says, but for one case.
        var played = chosen.map { AppRun.played($0, RunResult(text: $0.want, layout: Repo.abc.id), reveal: false) }
        played[0].sha256 = "changed"
        played[0].text = "changed"
        try FileManager.default.createDirectory(atPath: directory + "/run", withIntermediateDirectories: true)
        try AppRun(app: "com.apple.TextEdit", skipped: [:], played: played).write(to: directory + "/run")
        let compared = EvalContext.Capture()
        let status = EvalContext.$capture.withValue(compared) {
            EvalCommands.run(["fidelity", "--cases", directory + "/fidelity.jsonl", "--app-run", directory + "/run",
                              "--system", "oracle"] + layouts)
        }
        #expect(status == 0)
        #expect(compared.stdout.contains("played 20, final text differs in 1 (5.00 %)"), "\(compared.stdout)\(compared.stderr)")
        #expect(compared.stdout.contains("\"changed\""))
    }
}
