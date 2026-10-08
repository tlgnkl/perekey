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
        // Benchmarks InputMachine; scripts/bench.sh runs it in CI.
        .executableTarget(name: "perekey-bench", dependencies: ["PerekeyCore"]),
        .testTarget(
            name: "PerekeyCoreTests",
            dependencies: ["PerekeyCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PerekeyInputTests", dependencies: ["PerekeyCore", "PerekeyInput"]),
    ]
)
