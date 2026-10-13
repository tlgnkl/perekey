// SPDX-License-Identifier: GPL-3.0-or-later

/// Keeps a model in memory while it is used and unloads it after a while
/// without dictation, as Orca does (60 minutes by default; 10, 60 or never in
/// the settings).
///
/// A dictation holds the model from `begin` to `end`. The timer starts only
/// when the last holder ends: no input, no timers. Nothing unloads a held
/// model: `unload` waits until no one holds it, and the timer does nothing
/// while someone does. Loads and unloads run one after another: a load asked
/// for during an unload waits for it.
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
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var isLoaded = false
    /// Dictations holding the model now.
    public private(set) var holders = 0

    /// `unloadDelay` nil keeps the model until `unload`.
    public init(_ model: any VoiceModel, unloadDelay: Duration? = .seconds(3600),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) })
    {
        self.model = model
        self.unloadDelay = unloadDelay
        self.sleep = sleep
    }

    /// Holds the model and loads it, or waits for the load under way.
    /// Callers begin at the start of a dictation, while its audio is
    /// recorded, and `end` once they are done with it. A failed load holds
    /// nothing.
    public func begin() async throws {
        holders += 1
        stopTimer()
        do {
            try await ensureLoaded()
        } catch {
            end()
            throw error
        }
    }

    /// A holder is done: with the last one the unload timer starts.
    public func end() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
        startTimer()
    }

    /// Loads in the background after a download, so that the first
    /// dictation does not wait for CoreML to compile; unloads after the
    /// delay unless dictation uses it first.
    public func warmUp() async throws {
        try await begin()
        end()
    }

    /// A new delay applies to a timer already running, from now.
    public func setUnloadDelay(_ delay: Duration?) {
        unloadDelay = delay
        if timer != nil { startTimer() }
    }

    /// Unloads once no dictation holds the model.
    public func unload() async {
        stopTimer()
        while holders > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
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

    private func ensureLoaded() async throws {
        while !isLoaded {
            let task: Task<Void, any Error>
            if let loading {
                task = loading
            } else {
                let model = self.model
                let pendingUnload = unloading
                task = Task {
                    await pendingUnload?.value
                    try await model.prepare()
                }
                loading = task
            }
            do {
                try await task.value
            } catch {
                if loading == task { loading = nil }
                throw error
            }
            // An unload that took the load over leaves it unloaded: load again.
            if loading == task {
                loading = nil
                isLoaded = true
            }
        }
    }

    private func startTimer() {
        stopTimer()
        guard let unloadDelay, isLoaded, holders == 0 else { return }
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

    private func expire(_ generation: Int) async {
        guard generation == timerGeneration, holders == 0 else { return }
        timer = nil
        await unload()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        timerGeneration += 1
    }
}
