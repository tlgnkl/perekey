// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "Perekey",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Perekey", targets: ["Perekey"]),
    ],
    targets: [
        // Platform-independent logic: no AppKit, no Carbon. Fully unit-testable.
        .target(name: "PerekeyCore"),
        // System layer: event taps, Text Input Sources, accessibility. Main thread
        // and tap thread rules are in docs/PLAN.md, "Потоки".
        .target(name: "PerekeyInput", dependencies: ["PerekeyCore"]),
        // The menu bar app.
        .executableTarget(name: "Perekey", dependencies: ["PerekeyCore", "PerekeyInput"]),
        // Dev tool: dumps installed layouts as test fixtures.
        .executableTarget(name: "perekey-layout-dump", dependencies: ["PerekeyCore", "PerekeyInput"]),
        // Benchmarks InputMachine and the classifier; scripts/bench.sh runs it in CI.
        .executableTarget(name: "perekey-bench", dependencies: ["PerekeyCore"]),
        // Readers of third-party data and corpora for the two tools below.
        // Foundation is fine here: nothing of it ships in the app.
        .target(name: "PerekeyModelKit", dependencies: ["PerekeyCore"]),
        // Builds the language model from the data cache; scripts/build-model.sh.
        .executableTarget(name: "perekey-model", dependencies: ["PerekeyCore", "PerekeyModelKit"]),
        // Measures the classifier on the held-out corpus; scripts/eval.sh.
        .executableTarget(name: "perekey-eval", dependencies: ["PerekeyCore", "PerekeyModelKit"]),
        .testTarget(
            name: "PerekeyCoreTests",
            dependencies: ["PerekeyCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PerekeyInputTests", dependencies: ["PerekeyCore", "PerekeyInput"]),
        .testTarget(
            name: "PerekeyModelKitTests",
            dependencies: ["PerekeyCore", "PerekeyModelKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
