// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// What one run cost: wall time, CPU time, peak memory, and the energy of the
/// CPU, GPU and Neural Engine over the run. The peaks come from a sampler
/// every 50 ms; the energy from IOReport, which needs no root (`powermetrics`
/// does).
final class RunMeter: @unchecked Sendable {
    struct Report {
        var wallSeconds: Double
        /// User plus system CPU time of the process over the wall time: 1.0 is
        /// one core busy all the time.
        var cpuCores: Double
        var peakRSSMB: Double
        var peakFootprintMB: Double
        /// Average power over the run, watts, by IOReport's "Energy Model";
        /// empty when IOReport gives nothing.
        var watts: [String: Double]

        var json: [String: Any] {
            ["wall_s": wallSeconds, "cpu_cores": cpuCores, "peak_rss_mb": peakRSSMB,
             "peak_footprint_mb": peakFootprintMB, "watts": watts]
        }
    }

    private let lock = NSLock()
    private var peakRSS = 0.0
    private var peakFootprint = 0.0
    private var running = true
    private let start = ContinuousClock.now
    private let cpuStart = RunMeter.cpuSeconds()
    private let energy = EnergySampler()
    private var thread: Thread?

    init() {
        sample()
        let thread = Thread { [weak self] in
            while let self, self.lock.withLock({ self.running }) {
                self.sample()
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    /// The peaks since the start, or since the last `resetPeaks`.
    var peaks: (rss: Double, footprint: Double) { lock.withLock { (peakRSS, peakFootprint) } }

    func resetPeaks() {
        let now = MemorySnapshot.now()
        lock.withLock {
            peakRSS = now.rssMB
            peakFootprint = now.footprintMB
        }
    }

    func stop() -> Report {
        sample()
        lock.withLock { running = false }
        let elapsed = ContinuousClock.now - start
        let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let peaks = self.peaks
        return Report(wallSeconds: wall, cpuCores: (Self.cpuSeconds() - cpuStart) / max(wall, 1e-9),
                      peakRSSMB: peaks.rss, peakFootprintMB: peaks.footprint, watts: energy?.watts() ?? [:])
    }

    private func sample() {
        let now = MemorySnapshot.now()
        lock.withLock {
            peakRSS = max(peakRSS, now.rssMB)
            peakFootprint = max(peakFootprint, now.footprintMB)
        }
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}

/// The SoC's energy counters ("Energy Model" group of IOReport): CPU, GPU,
/// ANE and DRAM, for the whole machine, not this process. IOReport is a
/// private framework, so it is taken with `dlsym`; a measurement aid only.
final class EnergySampler: @unchecked Sendable {
    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64,
        CFTypeRef?
    ) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let channelName: ChannelString
    private let unitLabel: ChannelString
    private let integerValue: IntegerValue
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private let first: CFDictionary
    private let start = ContinuousClock.now

    init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannels.self),
              let createSubscription = symbol("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = symbol("IOReportCreateSamples", as: CreateSamples.self),
              let createDelta = symbol("IOReportCreateSamplesDelta", as: CreateDelta.self),
              let channelName = symbol("IOReportChannelGetChannelName", as: ChannelString.self),
              let unitLabel = symbol("IOReportChannelGetUnitLabel", as: ChannelString.self),
              let integerValue = symbol("IOReportSimpleGetIntegerValue", as: IntegerValue.self),
              let group = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, group)
        else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, channels, &subscribed, 0, nil),
              let first = createSamples(subscription, channels, nil)?.takeRetainedValue()
        else { return nil }
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.integerValue = integerValue
        self.subscription = subscription
        self.channels = channels
        self.first = first
    }

    /// Average watts since `init`, summed by kind: "cpu", "gpu", "ane",
    /// "dram", and `<kind>_s`, the seconds the counters cover. Without root
    /// the delta of IOReport is all zeros and the power manager's counters
    /// refresh only every minute or two, so each counter is read raw: its
    /// running total and the host time it was taken at. Short runs get nothing.
    func watts() -> [String: Double] {
        guard let now = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return [:] }
        let before = raw(first), after = raw(now)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var joules: [String: Double] = [:], covered: [String: Double] = [:]
        for (name, end) in after {
            guard let kind = Self.kind(of: name), let start = before[name], end.time > start.time else { continue }
            let seconds = Double(end.time - start.time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
            joules[kind, default: 0] += Double(end.value - start.value) * end.scale / seconds
            covered[kind] = min(covered[kind] ?? .infinity, seconds)
        }
        var result = joules
        for (kind, seconds) in covered { result[kind + "_s"] = seconds }
        return result
    }

    /// Channel name → (host time, running total, joules per unit), from a sample's raw elements.
    private func raw(_ sample: CFDictionary) -> [String: (time: UInt64, value: Int64, scale: Double)] {
        guard let list = (sample as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return [:] }
        var result: [String: (time: UInt64, value: Int64, scale: Double)] = [:]
        for channel in list {
            let cf = channel as CFDictionary
            guard let name = channelName(cf)?.takeUnretainedValue() as String?, Self.kind(of: name) != nil,
                  let data = channel["RawElements"] as? Data, data.count >= 40 else { continue }
            let unit = (unitLabel(cf)?.takeUnretainedValue() as String?) ?? ""
            let scale: Double = switch unit {
            case "mJ": 1e-3
            case "uJ", "µJ": 1e-6
            case "nJ": 1e-9
            default: 0
            }
            let time = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: Int64.self) }
            result[name] = (time, value, scale)
        }
        return result
    }

    /// Only the totals: "CPU Energy", "GPU Energy", "ANE…", "DRAM…". Per-core
    /// and per-cluster channels repeat what the totals hold.
    static func kind(of channel: String) -> String? {
        if channel == "CPU Energy" { return "cpu" }
        if channel == "GPU Energy" || channel == "GPU" { return "gpu" }
        if channel.hasPrefix("ANE") { return "ane" }
        if channel.hasPrefix("DRAM") { return "dram" }
        return nil
    }
}
