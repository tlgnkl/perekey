// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// Voice input is built only with PEREKEY_VOICE=1; releases set it (release.yml).
// Without the flag the package has no voice system layer and no dependencies, and the app
// builds as before. Build with the flag in its own scratch path
// (`PEREKEY_VOICE=1 swift build --scratch-path .build/voice`): both graphs
// then keep their own build state.
//
// The pins of the flagged graph live in Support/voice/Package.resolved, and the
// root Package.resolved is not committed: SwiftPM fetches every pin of a root
// file, so builds without the flag would clone the voice packages for nothing.
// The flagged scripts copy the pins to the root; scripts/voice-pins.sh updates
// and checks them.
let voice = Context.environment["PEREKEY_VOICE"] == "1"

// The typing recorder for the live measure (CONTRIBUTING.md, «Recording typing
// for the measure») is built only with PEREKEY_RECORD=1, on a developer's Mac.
// Every line of it is under `#if PEREKEY_RECORD`; releases never set the flag,
// and scripts/check-no-recorder.sh fails on a binary that has it. Build with
// the flag in its own scratch path (`.build/record`, `.build/voice-record` with
// voice); scripts/test.sh, bundle.sh and bench.sh pick it themselves.
let record = Context.environment["PEREKEY_RECORD"] == "1"
let recordSettings: [SwiftSetting] = record ? [.define("PEREKEY_RECORD")] : []

var dependencies: [Package.Dependency] = []
if voice {
    dependencies += [
        // Parakeet ASR, Silero VAD, diarization. Pinned exactly: the app loads
        // models through its own catalog, and the loaders it avoids are checked
        // by version. No traits: the NeMo text normalization engine (TTS, ITN)
        // stays out of the app.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        // WhisperKit.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ]
}

var targets: [Target] = [
    // Platform-independent logic: no AppKit, no Carbon. Fully unit-testable.
    .target(name: "PerekeyCore"),
    // Voice logic without system calls or third-party packages: settings, the
    // model catalog, the dictation machine. Built with and without the flag.
    .target(name: "PerekeyVoiceCore", dependencies: ["PerekeyCore"]),
    // System layer: event taps, Text Input Sources, accessibility. Main thread
    // and tap thread rules are in docs/PLAN.md, "Потоки".
    .target(name: "PerekeyInput", dependencies: ["PerekeyCore", "PerekeyVoiceCore"], swiftSettings: recordSettings),
    // The menu bar app.
    .executableTarget(
        name: "Perekey",
        dependencies: ["PerekeyCore", "PerekeyInput", "PerekeyVoiceCore", "Sparkle"]
            + (voice ? ["PerekeyVoice"] : []),
        swiftSettings: (voice ? [.define("PEREKEY_VOICE")] : []) + recordSettings
    ),
    // Sparkle 2, the official release XCFramework. scripts/bundle.sh embeds it in
    // Contents/Frameworks and signs it. To upgrade: take `version` and `checksum`
    // from Package.swift of the Sparkle tag.
    .binaryTarget(
        name: "Sparkle",
        url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
        checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
    ),
    // Dev tool: dumps installed layouts as test fixtures.
    .executableTarget(name: "perekey-layout-dump", dependencies: ["PerekeyCore", "PerekeyInput"]),
    // Benchmarks InputMachine and the classifier; scripts/bench.sh runs it in CI.
    // With PEREKEY_RECORD=1 it also times the machine with the typing recorder's
    // buffer on (PerekeyInput's RecordingBuffer), in memory, without a disk.
    .executableTarget(
        name: "perekey-bench",
        dependencies: ["PerekeyCore"] + (record ? ["PerekeyInput"] : []),
        swiftSettings: recordSettings
    ),
    // Dev tool: times the shared words of the voice dictionary in the personal lexicon store.
    .executableTarget(name: "perekey-shared-measure", dependencies: ["PerekeyCore", "PerekeyInput"]),
    // Dev tool: posts user-looking keystrokes for scripts/e2e.sh, and plays the cases of the quality
    // bench in a real app (`play`, docs/eval.md).
    .executableTarget(name: "perekey-e2e", dependencies: ["PerekeyCore", "PerekeyEvalKit"]),
    // Readers of third-party data and corpora for the two tools below.
    // Foundation is fine here: nothing of it ships in the app.
    // PerekeyDesk: a simulated replay of a recorded session runs on its desk.
    .target(name: "PerekeyModelKit", dependencies: ["PerekeyCore", "PerekeyDesk"]),
    // Builds the language model from the data cache; scripts/build-model.sh.
    .executableTarget(name: "perekey-model", dependencies: ["PerekeyCore", "PerekeyModelKit"]),
    // The system around InputMachine in memory: a text field with a caret,
    // the layout the app types in, retypes and deadlines (docs/eval.md).
    // No Foundation, like the core.
    .target(name: "PerekeyDesk", dependencies: ["PerekeyCore"]),
    // The quality bench: cases, the typist, the systems under test, scoring
    // and the run files (docs/eval.md). Foundation is fine: nothing of it
    // ships in the app.
    .target(name: "PerekeyEvalKit", dependencies: ["PerekeyCore", "PerekeyDesk", "PerekeyModelKit"]),
    // Measures the classifier on the held-out corpus (scripts/eval.sh) and
    // plays the cases of the quality bench.
    .executableTarget(name: "perekey-eval", dependencies: ["PerekeyCore", "PerekeyModelKit", "PerekeyEvalKit"]),
    // PerekeyModelKit for the replay of recorded sessions: its tests record
    // sessions on the test desk of these. With PEREKEY_RECORD=1, PerekeyInput
    // too: the app's typing recorder records on the same desk.
    .testTarget(
        name: "PerekeyCoreTests",
        dependencies: ["PerekeyCore", "PerekeyModelKit"] + (record ? ["PerekeyInput"] : []),
        resources: [.copy("Fixtures")],
        swiftSettings: recordSettings
    ),
    .testTarget(name: "PerekeyInputTests", dependencies: ["PerekeyCore", "PerekeyInput", "PerekeyVoiceCore"],
                swiftSettings: recordSettings),
    .testTarget(
        name: "PerekeyModelKitTests",
        dependencies: ["PerekeyCore", "PerekeyModelKit"],
        resources: [.copy("Fixtures")]
    ),
    .testTarget(name: "PerekeyVoiceCoreTests", dependencies: ["PerekeyCore", "PerekeyVoiceCore"]),
    .testTarget(
        name: "PerekeyEvalKitTests",
        dependencies: ["PerekeyCore", "PerekeyDesk", "PerekeyEvalKit", "PerekeyModelKit"],
        resources: [.copy("Fixtures")]
    ),
]

if voice {
    targets += [
        // Voice system layer: audio capture, model files, speech engines.
        // Models are downloaded only by its own store; CI greps Sources/ for
        // the loaders of FluidAudio and WhisperKit.
        .target(
            name: "PerekeyVoice",
            dependencies: [
                "PerekeyCore",
                "PerekeyInput",
                "PerekeyVoiceCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        // Dev tool: downloads, loads and measures speech models outside the app.
        .executableTarget(
            name: "perekey-voice-probe",
            dependencies: [
                "PerekeyVoice",
                "PerekeyVoiceCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "PerekeyVoiceTests",
            dependencies: [
                "PerekeyVoice",
                "PerekeyVoiceCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
    ]
}

let package = Package(
    name: "Perekey",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Perekey", targets: ["Perekey"]),
    ],
    dependencies: dependencies,
    targets: targets
)
