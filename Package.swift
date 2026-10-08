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
        // The menu bar app.
        .executableTarget(name: "Perekey", dependencies: ["PerekeyCore"]),
        .testTarget(name: "PerekeyCoreTests", dependencies: ["PerekeyCore"]),
    ]
)
