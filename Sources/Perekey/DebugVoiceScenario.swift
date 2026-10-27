// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG && PEREKEY_VOICE
import AppKit
import PerekeyCore
import PerekeyInput
import PerekeyVoice
import PerekeyVoiceCore
import SwiftUI

/// A live run of the Voice tab's model handling against Hugging Face, for
/// checking by hand: `PEREKEY_VOICE_SCENARIO=<dir> Perekey`.
///
/// Everything lives in `<dir>`: the settings file, the models, the managed
/// folder and the CoreML cache. The user's models and cache are never opened,
/// so "Delete all" here deletes nothing of theirs. Prints one line per step
/// and exits with 0 when every check held.
@MainActor
enum DebugVoiceScenario {
    private static var failures = 0

    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["PEREKEY_VOICE_SCENARIO"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run(in: directory)
            print(failures == 0 ? "SCENARIO OK" : "SCENARIO FAILED: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        NSApplication.shared.run()
    }

    private static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    private static func wait(_ what: String, seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        print("TIMEOUT \(what)")
        return false
    }

    private static func run(in directory: URL) async {
        let file = VoiceSettingsFile(url: directory.appending(path: "voice.json"))
        try? FileManager.default.removeItem(at: file.url)
        let settings = VoiceSettingsStore(file: file, managed: ManagedSettings())
        let locations = VoiceModelLocations(
            models: directory.appending(path: "models", directoryHint: .isDirectory),
            managed: directory.appending(path: "managed", directoryHint: .isDirectory),
            coreMLCache: directory.appending(path: "cache", directoryHint: .isDirectory))
        let controller = VoiceModelsController(
            settings: settings, store: VoiceModelStore(locations: locations, managed: settings.managed))
        var ready: [String] = []
        controller.onModelReady = { ready.append($0) }
        controller.start()
        let parakeet = VoiceSettings.defaultModel
        let whisper = ModelCatalog.recognizers.first { $0.engine == .whisperKit }!.id
        func state(_ id: String) -> VoiceModelState? { controller.statuses.first { $0.id == id }?.state }
        func received(_ id: String) -> Int64 {
            switch state(id) {
            case let .downloading(r), let .partial(r), let .waitingForNetwork(r): r
            default: 0
            }
        }
        _ = await wait("statuses", seconds: 10) { !controller.statuses.isEmpty }
        print("models folder: \(controller.store.locations.models.path)")

        // Voice off: nothing goes out.
        check(VoiceHTTP.shared.allowed.isEmpty, "voice off: the network is closed")
        controller.download(parakeet)
        try? await Task.sleep(for: .seconds(2))
        check(VoiceHTTP.shared.requests.isEmpty && state(parakeet) == .absent, "voice off: Download starts nothing")

        // Voice on: the network opens for model downloads only.
        settings.update { $0.isEnabled = true }
        check(VoiceHTTP.shared.allowed == [.modelDownload], "voice on: model downloads allowed")

        // Start from a window, close the window: the download goes on.
        var window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let store = SettingsStore(file: SettingsFile(url: directory.appending(path: "settings.json"), defaults: debugDefaults()))
        window?.contentView = NSHostingView(rootView: VoicePane(controller: controller, store: store,
                                                                recording: ShortcutRecording(store: store)))
        window?.isReleasedWhenClosed = false
        window?.orderFrontRegardless()
        controller.download(parakeet)
        _ = await wait("parakeet started", seconds: 60) { received(parakeet) > 20_000_000 }
        window?.close()
        window = nil
        let atClose = received(parakeet)
        try? await Task.sleep(for: .seconds(6))
        check(received(parakeet) > atClose, "closing the window keeps the download going (\(atClose) → \(received(parakeet)))")

        // Cancel keeps what arrived, Resume goes on from there.
        controller.cancel(parakeet)
        _ = await wait("cancelled", seconds: 15) { if case .partial = state(parakeet) { true } else { false } }
        let atCancel = received(parakeet)
        try? await Task.sleep(for: .seconds(3))
        check(atCancel > 0 && received(parakeet) == atCancel, "Cancel stops it and keeps \(atCancel) bytes")
        controller.download(parakeet)
        let start = Date()
        let done = await wait("parakeet ready", seconds: 1500) { state(parakeet) == .ready }
        check(done && ready.contains(parakeet), "Resume ends ready, onModelReady fired (\(Int(Date().timeIntervalSince(start))) s)")

        // The second model.
        controller.download(whisper)
        let whisperDone = await wait("whisper ready", seconds: 1800) { state(whisper) == .ready }
        check(whisperDone && ready.contains(whisper), "Whisper turbo downloads and is ready")
        let usage = await controller.store.diskUsage()
        print("disk: models \(usage.models) cache \(usage.cache)")
        check(usage.models > 1_000_000_000, "disk use counts both models")

        // Delete one, then everything.
        controller.delete(parakeet)
        _ = await wait("parakeet deleted", seconds: 30) { state(parakeet) == .absent }
        check(state(parakeet) == .absent && state(whisper) == .ready, "Delete removes one model only")
        controller.deleteAll()
        _ = await wait("all deleted", seconds: 30) { state(whisper) == .absent }
        check(state(whisper) == .absent, "Delete all removes the rest")

        // Voice off in the middle of a download.
        controller.download(parakeet)
        _ = await wait("started again", seconds: 60) { received(parakeet) > 5_000_000 }
        settings.update { $0.isEnabled = false }
        check(VoiceHTTP.shared.allowed.isEmpty, "voice off again: the network is closed")
        let stopped = await wait("stopped", seconds: 30) { if case .partial = state(parakeet) { true } else { false } }
        check(stopped, "voice off stops the running download")
        controller.deleteAll()
        try? await Task.sleep(for: .seconds(2))
    }
}
#endif
