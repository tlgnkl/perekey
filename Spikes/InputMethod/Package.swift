// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// Spike: Perekey as an input method (InputMethodKit). Not part of the app and
// not built by the root package. PerekeyCore, PerekeyInput and PerekeyVoiceCore
// are symlinks to the app's own sources, so the spike runs the same LayoutMap,
// LayoutReader and Classifier as the app does.
let package = Package(
    name: "PerekeyIMSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PerekeyCore"),
        .target(name: "PerekeyVoiceCore", dependencies: ["PerekeyCore"]),
        .target(name: "PerekeyInput", dependencies: ["PerekeyCore", "PerekeyVoiceCore"]),
        // The word logic of both strategies over a client protocol: no AppKit, testable.
        .target(name: "SpikeCore", dependencies: ["PerekeyCore"]),
        // The input method process: IMKServer and the controller.
        .executableTarget(
            name: "PerekeyIMSpike",
            dependencies: ["SpikeCore", "PerekeyCore", "PerekeyInput"],
            // IMKInputController has no isolation annotations, and IMK calls it on
            // the main thread only; Swift 6 cannot see that through `Any!` senders.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("InputMethodKit")]
        ),
        // Drives the input method through the real text system of its own
        // windows (NSTextView, NSSearchField, WKWebView) and reports the text.
        .executableTarget(
            name: "imk-harness",
            dependencies: ["SpikeCore", "PerekeyCore", "PerekeyInput"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .testTarget(name: "SpikeCoreTests", dependencies: ["SpikeCore", "PerekeyCore"]),
    ]
)
