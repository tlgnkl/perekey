// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyDesk
@testable import PerekeyEvalKit

/// The repository, for eval/ and the core's fixtures.
enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

    static let library = try! LayoutLibrary(directory: path("eval/layouts"))

    static var abc: LayoutMap { library["ABC"]! }
    static var russian: LayoutMap { library["Russian"]! }

    static let classifier = Classifier(model: ModelFixture.model)

    static func fixture(_ name: String) -> String {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!.path
    }
}

/// Builds cases for tests: a script of steps, the tokens from `want`.
enum Cases {
    static func make(_ script: [Step], want: String, warmup: [Step]? = nil, start: String = "ABC",
                     layouts: [String] = ["ABC", "Russian"], env: Env? = nil, tokens: [TokenSpec]? = nil,
                     scoring: EvalCase.Scoring? = nil, checks: [Check]? = nil, fold: [EvalCase.Fold]? = nil,
                     scenario: String = "clean.cold", suite: String = "test") -> EvalCase
    {
        var item = EvalCase(suite: suite, scenario: scenario, split: .dev, layouts: layouts, start: start, env: env,
                            warmup: warmup, script: script, want: want, scoring: scoring, checks: checks, fold: fold)
        if scoring != .case {
            item.tokens = tokens ?? item.measuredWant.map {
                TokenSpec(t: $0, lang: $0.contains(where: { ("a"..."z").contains($0.lowercased()) }) ? "en" : "ru")
            }
        }
        return try! item.identified()
    }

    /// Plays a case on the machine with the fixture model, and on Null.
    static func play(_ item: EvalCase, system: SystemName = .machine) throws -> Runner.Played {
        var config = Runner.Config()
        config.system = system
        config.classifier = Repo.classifier
        var runner = Runner(config: config, library: Repo.library)
        return try runner.play(item)
    }
}

/// Builds `RunResult`s for the scorer.
func result(_ text: String) -> RunResult {
    RunResult(text: text, layout: Repo.abc.id)
}
