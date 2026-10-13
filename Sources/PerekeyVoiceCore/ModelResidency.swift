// SPDX-License-Identifier: GPL-3.0-or-later

/// Keeps a model in memory while it is used and unloads it after a while
/// without dictation, as Orca does (60 minutes by default; 10, 60 or never in
/// the settings). The timer starts only when a dictation is over: no input,
/// no timers. A `load` stops it.
///
/// Loads and unloads run one after another: a load asked for during an
/// unload waits for it, so the model never sees both at once.
public actor ModelResidency {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public nonisolated let model: any VoiceModel
    private let sleep: Sleep
    private var unloadDelay: Duration?
    private var loading: Task<Void, any Error>?
    private var unloading: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    /// Bumped whenever the timer is stopped: an older timer does nothing.
    private var timerGeneration = 0
    public private(set) var isLoaded = false

    /// `unloadDelay` nil keeps the model until `unload`.
    public init(_ model: any VoiceModel, unloadDelay: Duration? = .seconds(3600),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) })
    {
        self.model = model
        self.unloadDelay = unloadDelay
        self.sleep = sleep
    }

    /// Loads the model, or waits for the load already under way. Callers
    /// load at the start of a dictation, while its audio is recorded.
    public func load() async throws {
        stopTimer()
        if isLoaded { return }
        if let loading { return try await loading.value }
        let model = self.model
        let pendingUnload = unloading
        let task = Task {
            await pendingUnload?.value
            try await model.prepare()
        }
        loading = task
        do {
            try await task.value
        } catch {
            if loading == task { loading = nil }
            throw error
        }
        // An unload during the load took it over.
        if loading == task {
            loading = nil
            isLoaded = true
        }
    }

    /// A dictation is over: the unload timer starts.
    public func used() {
        stopTimer()
        guard let unloadDelay, isLoaded else { return }
        let generation = timerGeneration
        let sleep = self.sleep
        timer = Task { [weak self] in
            do {
                try await sleep(unloadDelay)
            } catch {
                return
            }
            await self?.expire(generation)
        }
    }

    /// Loads in the background after a download, so that the first
    /// dictation does not wait for CoreML to compile; unloads after the
    /// delay unless dictation uses it first.
    public func warmUp() async throws {
        try await load()
        used()
    }

    /// A new delay applies to a timer already running, from now.
    public func setUnloadDelay(_ delay: Duration?) {
        unloadDelay = delay
        if timer != nil { used() }
    }

    public func unload() async {
        stopTimer()
        let wasLoading = loading
        let wasLoaded = isLoaded
        loading = nil
        isLoaded = false
        guard wasLoaded || wasLoading != nil else {
            await unloading?.value
            return
        }
        let previous = unloading
        let model = self.model
        let task = Task {
            await previous?.value
            _ = try? await wasLoading?.value
            await model.unload()
        }
        unloading = task
        await task.value
        if unloading == task { unloading = nil }
    }

    /// Whether the unload timer runs.
    public var isTimerRunning: Bool { timer != nil }

    private func expire(_ generation: Int) async {
        guard generation == timerGeneration else { return }
        timer = nil
        await unload()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        timerGeneration += 1
    }
}
