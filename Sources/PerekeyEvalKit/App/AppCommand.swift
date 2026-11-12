// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The machine under the bench's real-app run: `perekey-e2e` gives it, the tests give a fake.
public protocol AppPlatform {
    var probe: InputGuard.Probe { get }
    /// The ids of the layouts the system has on; nil when it cannot say.
    func enabledLayouts() -> Set<String>?
    func makeDriver(bundle: String) throws -> any AppDriver
}

/// `perekey-e2e play` (docs/eval.md, «Настоящая программа»):
///
///     perekey-e2e play --cases <files or directory> --app TextEdit --out <run dir>
///                      [--only <suite,...>] [--split dev|test|all] [--limit <n>] [--reveal-test]
///                      [--dry-run]
///
/// Exit status: 0 played, 2 bad input, 3 the screen is locked, 4 someone used the keyboard or the mouse
/// (or the machine does not say), 5 the app is not in front.
public enum AppCommand {
    /// The apps that have a driver, by the name on the command line.
    public static let apps: [String: String] = ["TextEdit": "com.apple.TextEdit"]

    public static func run(_ arguments: [String], platform: any AppPlatform) -> Int32 {
        do {
            let parsed = try Arguments(arguments)
            return try play(parsed, platform: platform)
        } catch let refusal as InputGuard.Refusal {
            EvalContext.err("perekey-e2e: \(refusal)")
            return refusal.exitCode
        } catch {
            EvalContext.err("perekey-e2e: \(error)")
            return 2
        }
    }

    static func play(_ parsed: Arguments, platform: any AppPlatform) throws -> Int32 {
        let name = parsed.value("--app") ?? "TextEdit"
        guard let bundle = apps[name] else {
            throw EvalError.input("--app \(apps.keys.sorted().joined(separator: "|")): no driver for \(name)")
        }
        let dry = parsed.flag("--dry-run")
        let library = try parsed.library()
        let files = try CaseFiles.expand(parsed.values("--cases"))
        guard !files.isEmpty else { throw EvalError.input("play: --cases <files or directory> is required") }
        let items = try EvalCommands.selected(files, parsed, library: library)
        guard !items.contains(where: \.isPersonal) else {
            throw EvalError.input("play: a personal set is not played in an app: its words would reach the screen")
        }
        let enabled = platform.enabledLayouts()
        var skipped: [String: Int] = [:]
        var playable: [EvalCase] = []
        for item in items {
            if let reason = AppSupport.unsupported(item, bundle: bundle, enabled: enabled, library: library) {
                skipped[reason, default: 0] += 1
            } else {
                playable.append(item)
            }
        }
        if let limit = try parsed.value("--limit").map({ text -> Int in
            guard let number = Int(text), number > 0 else { throw EvalError.input("--limit needs a positive number") }
            return number
        }) { playable = Array(playable.prefix(limit)) }

        let typist = Typist()
        var seconds = 0.0
        for item in playable {
            let events = try typist.events(for: item, layouts: library)
            seconds += (events.last?.time ?? 0) - (events.first?.time ?? 0) + AppSystem.Options().settleSeconds
        }
        EvalContext.out("\(items.count) cases: \(playable.count) to play, \(items.count - playable.count) not played"
            + (skipped.isEmpty ? "" : " (" + skipped.keys.sorted().map { "\($0) \(skipped[$0]!)" }.joined(separator: ", ") + ")"))
        EvalContext.out(String(format: "about %.1f min of typing, %@", seconds / 60, name))
        if let enabled {
            if skipped["layouts"] != nil {
                EvalContext.out("layouts on in the system: " + enabled.sorted().joined(separator: ", ")
                    + "; the cases want exactly the layouts they name (eval/layouts)")
            }
        } else {
            EvalContext.out("note: the enabled layouts are not known; the layout of the cases is not checked")
        }

        var input = InputGuard(probe: platform.probe)
        if dry {
            do {
                try input.check(app: bundle)
                EvalContext.out("dry run: the guard would let the keys through now; nothing was posted")
            } catch let refusal as InputGuard.Refusal {
                EvalContext.out("dry run: the guard would stop the run now: \(refusal); nothing was posted")
            }
            return 0
        }
        guard let out = parsed.value("--out") else { throw EvalError.input("play: --out <run dir> is required") }
        guard !playable.isEmpty else { throw EvalError.input("play: no case the app can play") }
        // Before the driver touches the app: no key, no change of the field, on a refusal.
        try input.check(app: bundle)
        let driver = try platform.makeDriver(bundle: bundle)
        let system = AppSystem(driver: driver)
        var config = Runner.Config()
        config.revealTest = parsed.flag("--reveal-test")
        var runner = Runner(config: config, library: library)
        var scores: [CaseScore] = []
        var records: [AppRun.Played] = []
        var aborted: InputGuard.Refusal?
        for item in playable {
            do {
                let played = try runner.playApp(item) { item, events in
                    try system.run(item, events: events, library: library, input: &input, app: bundle)
                }
                scores.append(played.score)
                records.append(AppRun.played(item, played.out, reveal: config.revealTest))
            } catch let refusal as InputGuard.Refusal {
                aborted = refusal
                break
            }
        }
        let info = RunFiles.Info(
            commit: GitCommit.current(), models: [:], system: "app", settings: nil, options: nil,
            files: try files.map { .init(path: $0, sha256: try Runner.sha256(file: $0)) },
            split: parsed.value("--split") ?? "all", only: parsed.value("--only")?.split(separator: ",").map(String.init),
            tier: nil, testRevealed: config.revealTest
        )
        try RunFiles.write(scores, info: info, to: out)
        try AppRun(app: bundle, skipped: skipped, played: records, aborted: aborted?.description).write(to: out)
        EvalContext.out(Console.summary(Summary(scores)), terminator: "")
        if let aborted {
            EvalContext.err("perekey-e2e: stopped after \(records.count) of \(playable.count) cases: \(aborted)")
            return aborted.exitCode
        }
        return 0
    }
}
