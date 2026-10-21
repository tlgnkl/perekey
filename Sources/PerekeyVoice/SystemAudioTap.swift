// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import os

/// Whose audio a call recording takes from the system output.
public enum SystemAudioSource: Sendable, Equatable, CustomStringConvertible {
    /// One app by bundle ID, with the helper processes that play its audio:
    /// a browser's GPU or renderer process, a WebView.
    case app(bundleID: String)
    /// These processes only.
    case processes([pid_t])
    /// Everything the Mac plays, except this process.
    case system

    public var description: String {
        switch self {
        case .app(let bundleID): bundleID
        case .processes(let pids): "pid " + pids.map(String.init).joined(separator: ",")
        case .system: "system"
        }
    }
}

/// A process Core Audio knows: one that has used an audio device.
public struct AudioProcess: Sendable, Hashable, CustomStringConvertible {
    public let id: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    /// The process macOS holds responsible for this one: Safari for its WebKit
    /// GPU process. The process itself when it stands alone.
    public let responsiblePID: pid_t
    public let isRunningOutput: Bool

    public init(id: AudioObjectID, pid: pid_t, bundleID: String?, responsiblePID: pid_t, isRunningOutput: Bool) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.responsiblePID = responsiblePID
        self.isRunningOutput = isRunningOutput
    }

    public var description: String {
        "\(bundleID ?? "?") pid \(pid)" + (responsiblePID != pid && responsiblePID > 0 ? " (of \(responsiblePID))" : "")
            + (isRunningOutput ? " playing" : "")
    }
}

/// The processes of `kAudioHardwarePropertyProcessObjectList`, read on each call.
public enum AudioProcessList {
    /// `withResponsibility: false` leaves `responsiblePID` as the process itself.
    public static func all(withResponsibility: Bool = true) -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let ids: [AudioObjectID] = MicrophoneList.array(system, kAudioHardwarePropertyProcessObjectList) else {
            return []
        }
        return ids.compactMap { id in
            guard let pid: pid_t = MicrophoneList.value(id, kAudioProcessPropertyPID) else { return nil }
            let running: UInt32 = MicrophoneList.value(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            let bundleID = MicrophoneList.string(id, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            return AudioProcess(id: id, pid: pid, bundleID: bundleID, responsiblePID: withResponsibility ? AppHelpers.responsiblePID(pid) : pid,
                                isRunningOutput: running != 0)
        }
    }

    /// The process object of a PID, nil until the process has used audio.
    public static func object(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// The PIDs of the running app with this bundle ID.
    public static func appPIDs(bundleID: String) -> Set<pid_t> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
    }

    /// The processes a tap of `source` takes, or for `.system` leaves out.
    /// `byResponsibility: false` matches helpers by bundle ID only.
    static func members(of source: SystemAudioSource, in processes: [AudioProcess], appPIDs: Set<pid_t>,
                        ownPID: pid_t, byResponsibility: Bool = true) -> [AudioProcess] {
        switch source {
        case .app(let bundleID):
            return processes.filter {
                AppHelpers.belongs($0, toApp: bundleID, appPIDs: appPIDs, byResponsibility: byResponsibility)
            }
        case .processes(let pids):
            return processes.filter { pids.contains($0.pid) }
        case .system:
            return processes.filter { $0.pid == ownPID }
        }
    }
}

/// Which processes play an app's audio, for a tap by process list (macOS
/// before 26; from 26 the tap names the bundle ID and Core Audio follows the
/// app itself, see `SystemAudioTap.Matching`).
///
/// An app often plays through helpers. Chrome's carry its bundle ID with a
/// suffix (`com.google.Chrome.helper`), but Safari plays through WebKit's
/// GPU process, `com.apple.WebKit.GPU`, which bears no Safari ID and serves
/// every WebKit app at once. What ties it to Safari is the process macOS holds
/// responsible for it, and only `responsibility_get_pid_responsible_for_pid`
/// of libsystem tells that. The function is not in the SDK, so it is looked
/// up at run time: if a macOS drops it, helpers fall back to the bundle ID
/// prefix and Safari's audio is missed rather than the app failing to load.
enum AppHelpers {
    /// The process plays for the app: the app itself, a helper whose bundle
    /// ID extends the app's, or a process the app is responsible for.
    static func belongs(_ process: AudioProcess, toApp bundleID: String, appPIDs: Set<pid_t>,
                        byResponsibility: Bool = true) -> Bool {
        if let id = process.bundleID, id == bundleID || id.hasPrefix(bundleID + ".") {
            return true
        }
        return appPIDs.contains(process.pid) || byResponsibility && appPIDs.contains(process.responsiblePID)
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                                 "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFunction.self) }

    /// Whether the run-time lookup found the function.
    static var knowsResponsibility: Bool { responsible != nil }

    /// The responsible process, or the process itself when unknown.
    ///
    /// Never called on macOS 26+: there the tap names the app by bundle ID
    /// and Core Audio finds its helpers, so a private function is not worth
    /// its risk. Every caller (the tap's list, «Вся система», the source
    /// picker) goes through here, and the process stands for itself.
    static func responsiblePID(_ pid: pid_t) -> pid_t {
        if #available(macOS 26.0, *) { return pid }
        return responsible?(pid) ?? pid
    }
}

public enum SystemAudioTapError: Error, Equatable, CustomStringConvertible {
    /// `kAudioDevicePermissionsError`: "System Audio Recording" is off for the app.
    case notPermitted(String)
    case tap(OSStatus)
    case aggregate(OSStatus)
    case start(OSStatus)
    case noFormat

    public var description: String {
        switch self {
        case .notPermitted(let step): "not permitted (\(step): kAudioDevicePermissionsError)"
        case .tap(let status): "AudioHardwareCreateProcessTap: \(fourCC(status))"
        case .aggregate(let status): "AudioHardwareCreateAggregateDevice: \(fourCC(status))"
        case .start(let status): "AudioDeviceStart: \(fourCC(status))"
        case .noFormat: "the tap has no format"
        }
    }
}

/// What the tap tells its owner besides the audio.
public enum SystemAudioEvent: Sendable {
    /// The processes the tap takes changed: the description was rewritten on
    /// the live tap.
    case processes([AudioProcess])
    /// The output device or the tap's format changed: the tap and its
    /// aggregate were built again. The audio has a gap of `gap` seconds.
    case rebuilt(reason: String, format: String, gap: Double)
    /// Only zeros for `seconds` while a tapped process plays: likely no permission.
    case silent(seconds: Double)
    /// Sound came again after `.silent`.
    case sound
    /// The tap did not come back after a change; capture is off.
    case failed(String)
}

/// The system audio of a call: a Core Audio process tap read through a private
/// aggregate device that holds the tap alone. Its sink gets 16 kHz mono, the
/// mix of the tap's channels, with the `mHostTime` of each block, on a queue
/// of its own. `AudioCapture` keeps the microphone; the two tracks meet on
/// the host clock.
///
/// The tap follows the source: a new helper process of the app rewrites
/// `kAudioTapPropertyDescription` on the live tap, without a gap. A new output
/// device or tap format builds the tap and the aggregate again, and the sink
/// sees `.deviceChanged`.
@available(macOS 14.2, *)
public actor SystemAudioTap {
    private let queue = DispatchSerialQueue(label: "app.perekey.system-audio", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let ioQueue = DispatchQueue(label: "app.perekey.system-audio.io", qos: .userInteractive)

    public let source: SystemAudioSource
    /// How the description names an app.
    public enum Matching: Sendable, CustomStringConvertible {
        /// macOS 26+: the bundle ID in `CATapDescription.bundleIDs` with
        /// `processRestoreEnabled`; Core Audio takes the app's processes and
        /// adds them again when the app restarts.
        case bundleID
        /// The process objects of the app and its helpers (`AppHelpers`),
        /// rewritten on the live tap as processes come and go.
        case processes
        /// Both, for comparison.
        case processesAndBundleID

        /// The bundle ID where macOS takes it, else the process list.
        public static var automatic: Matching {
            if #available(macOS 26.0, *) { .bundleID } else { .processes }
        }

        public var description: String {
            switch self {
            case .bundleID: "bundle ID"
            case .processes: "process list"
            case .processesAndBundleID: "process list and bundle ID"
            }
        }
    }

    public let matching: Matching
    private let onEvent: @Sendable (SystemAudioEvent) -> Void

    private var sink: (any AudioSink)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private let tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var reader: TapReader?
    private var listeners: [Listener] = []
    private var watchdog: DispatchSourceTimer?
    /// Bumped by each change notice; a rebuild runs for the last of a burst only.
    private var changeGeneration = 0
    private var silentReported = false

    /// The processes in the tap's description: taken, or for `.system` left out.
    public private(set) var processes: [AudioProcess] = []
    public private(set) var format = AudioStreamBasicDescription()
    public private(set) var isRunning = false
    public private(set) var rebuilds = 0

    public init(source: SystemAudioSource, matching: Matching = .automatic,
                onEvent: @escaping @Sendable (SystemAudioEvent) -> Void = { _ in }) {
        self.source = source
        self.matching = matching
        self.onEvent = onEvent
    }

    /// Creates the tap and starts reading it. The first start asks for
    /// "System Audio Recording"; macOS answers before the user clicks, so a
    /// denied or pending permission may also show as zeros (`.silent`).
    public func start(_ sink: any AudioSink) throws {
        guard !isRunning else { return }
        self.sink = sink
        processes = currentMembers()
        if !waitsForProcesses {
            do {
                try build()
            } catch {
                teardown()
                self.sink = nil
                throw error
            }
        }
        isRunning = true
        listen()
        startWatchdog()
    }

    /// A tap of listed processes with none of them playing yet takes
    /// nothing, so it is not made: the first process to come builds it.
    private var waitsForProcesses: Bool {
        source != .system && processes.isEmpty && !namesBundleID
    }

    /// The description names the app by bundle ID (macOS 26+).
    private var namesBundleID: Bool {
        guard #available(macOS 26.0, *), case .app = source else { return false }
        return matching != .processes
    }

    /// The bundle ID alone: Core Audio keeps the app's processes, no list.
    private var followsBundleID: Bool { namesBundleID && matching == .bundleID }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        watchdog?.cancel()
        watchdog = nil
        for listener in listeners {
            listener.remove()
        }
        listeners = []
        teardown()
        sink = nil
    }

    /// Seconds of zeros the sink got in a row, at the last block.
    public var silentSeconds: Double { reader?.silentSeconds ?? 0 }
    /// Blocks and frames read since the last build.
    public var counts: (blocks: Int, frames: Int) { reader?.counts ?? (0, 0) }

    // MARK: Tap and aggregate

    private func build() throws {
        let description = makeDescription()
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else {
            throw tapStatus == kAudioDevicePermissionsError
                ? SystemAudioTapError.notPermitted("tap") : SystemAudioTapError.tap(tapStatus)
        }
        tapID = tap
        guard var format: AudioStreamBasicDescription = MicrophoneList.value(tap, kAudioTapPropertyFormat),
              format.mSampleRate > 0, format.mChannelsPerFrame > 0
        else { throw SystemAudioTapError.noFormat }
        self.format = format
        let tapUID = MicrophoneList.string(tap, kAudioTapPropertyUID) ?? tapUUID.uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "app.perekey.call.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Perekey call",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 1]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard aggregateStatus == noErr else {
            throw aggregateStatus == kAudioDevicePermissionsError
                ? SystemAudioTapError.notPermitted("aggregate") : SystemAudioTapError.aggregate(aggregateStatus)
        }
        aggregateID = device
        let reader = try TapReader(format: &format, sink: sink)
        self.reader = reader
        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { _, input, inputTime, _, _ in
            reader.read(input, time: inputTime)
        }
        guard procStatus == noErr, let proc else { throw SystemAudioTapError.start(procStatus) }
        ioProc = proc
        let startStatus = AudioDeviceStart(device, proc)
        guard startStatus == noErr else {
            throw startStatus == kAudioDevicePermissionsError
                ? SystemAudioTapError.notPermitted("start") : SystemAudioTapError.start(startStatus)
        }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregateID, ioProc)
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        reader?.finish()
        ioProc = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        reader = nil
    }

    private func makeDescription() -> CATapDescription {
        // An app named by bundle ID needs no list; `.system` always leaves
        // this process out by its object as well.
        let ids = followsBundleID ? [] : processes.map(\.id)
        let description = switch source {
        case .system: CATapDescription(stereoGlobalTapButExcludeProcesses: ids)
        case .app, .processes: CATapDescription(stereoMixdownOfProcesses: ids)
        }
        if #available(macOS 26.0, *), namesBundleID || source == .system && matching != .processes {
            switch source {
            case .app(let bundleID):
                description.bundleIDs = [bundleID]
                description.isProcessRestoreEnabled = true
            case .system:
                if let own = Bundle.main.bundleIdentifier {
                    description.bundleIDs = [own]
                }
            case .processes:
                break
            }
        }
        description.uuid = tapUUID
        description.name = "Perekey call"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    private func currentMembers() -> [AudioProcess] {
        let appPIDs = if case .app(let bundleID) = source { AudioProcessList.appPIDs(bundleID: bundleID) } else { Set<pid_t>() }
        // With the bundle ID in the description the list only tells the zero
        // detector whether the app plays, so it does without the private call.
        let byResponsibility = !followsBundleID
        return AudioProcessList.members(of: source, in: AudioProcessList.all(withResponsibility: byResponsibility),
                                        appPIDs: appPIDs, ownPID: getpid(), byResponsibility: byResponsibility)
    }

    // MARK: Changes

    private func listen() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        listeners = [
            Listener(system, kAudioHardwarePropertyProcessObjectList, queue: queue) { [weak self] in
                Task { await self?.processListChanged() }
            },
            Listener(system, kAudioHardwarePropertyDefaultOutputDevice, queue: queue) { [weak self] in
                Task { await self?.deviceChanged("default output device") }
            },
            Listener(tapID, kAudioTapPropertyFormat, queue: queue) { [weak self] in
                Task { await self?.deviceChanged("tap format") }
            },
        ].compactMap { $0 }
    }

    /// A process came or went: when the set of tapped ones changed, rewrite the
    /// description of the live tap.
    private func processListChanged() {
        guard isRunning else { return }
        let members = currentMembers()
        guard Set(members.map(\.id)) != Set(processes.map(\.id)) else { return }
        processes = members
        if tapID == kAudioObjectUnknown {
            guard !waitsForProcesses else { return }
            do {
                try build()
            } catch {
                teardown()
                onEvent(.failed(String(describing: error)))
                return
            }
            for listener in listeners {
                listener.remove()
            }
            listen()
            onEvent(.processes(members))
            return
        }
        guard !followsBundleID else {
            // Core Audio follows the bundle ID by itself.
            onEvent(.processes(members))
            return
        }
        let description = makeDescription()
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        // The property's value is the CATapDescription pointer itself.
        var reference = Unmanaged.passUnretained(description).toOpaque()
        let status = withExtendedLifetime(description) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size),
                                       &reference)
        }
        if status != noErr {
            onEvent(.failed("kAudioTapPropertyDescription: \(fourCC(status))"))
        }
        onEvent(.processes(members))
    }

    /// Several notices come for one switch; the rebuild waits for the burst
    /// to settle.
    private func deviceChanged(_ reason: String) {
        guard isRunning else { return }
        changeGeneration += 1
        let generation = changeGeneration
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            Task { await self?.rebuild(reason, generation: generation) }
        }
    }

    private func rebuild(_ reason: String, generation: Int) {
        guard isRunning, generation == changeGeneration else { return }
        let started = mach_absolute_time()
        let lastBlock = reader?.lastHostTime ?? started
        for listener in listeners {
            listener.remove()
        }
        listeners = []
        teardown()
        sink?.captureInterrupted(.deviceChanged)
        processes = currentMembers()
        guard !waitsForProcesses else {
            // The app went quiet meanwhile: the next process builds the tap.
            listen()
            return
        }
        do {
            try build()
        } catch {
            isRunning = false
            // No tap to watch: the zero detector would only keep the actor busy.
            watchdog?.cancel()
            watchdog = nil
            sink?.captureInterrupted(.failed(String(describing: error)))
            onEvent(.failed(String(describing: error)))
            return
        }
        rebuilds += 1
        listen()
        let gap = HostTime.seconds(mach_absolute_time() - min(lastBlock, started))
        onEvent(.rebuilt(reason: reason, format: describe(format), gap: gap))
    }

    // MARK: Zeros

    /// Once a second: zeros for more than 10 s while a tapped process plays
    /// mean the permission is off (or the bug of macOS 26.5 betas).
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            Task { await self?.checkSilence() }
        }
        timer.resume()
        watchdog = timer
    }

    private func checkSilence() {
        guard isRunning, let reader else { return }
        let silent = reader.silentSeconds
        guard silent > 10 else {
            if silentReported {
                silentReported = false
                onEvent(.sound)
            }
            return
        }
        guard !silentReported, sourcePlays() else { return }
        silentReported = true
        onEvent(.silent(seconds: silent))
    }

    private func sourcePlays() -> Bool {
        let all = AudioProcessList.all(withResponsibility: false)
        switch source {
        case .system:
            return all.contains { $0.pid != getpid() && $0.isRunningOutput }
        case .app, .processes:
            let tapped = Set(processes.map(\.id))
            return all.contains { tapped.contains($0.id) && $0.isRunningOutput }
        }
    }
}

/// Turns the tap's blocks into 16 kHz mono for the sink. Called on the IO
/// queue only, one block at a time.
final class TapReader: @unchecked Sendable {
    private let sink: (any AudioSink)?
    private let channels: Int
    private let interleaved: Bool
    private let resampler: Resampler
    private var mono: [Float] = []
    private let state = OSAllocatedUnfairLock(initialState: State())

    struct State {
        var blocks = 0
        var frames = 0
        var lastHostTime: UInt64 = 0
        /// Host time of the first block of the current run of zeros, 0 when the last block had sound.
        var silentSince: UInt64 = 0
        var silentSeconds: Double = 0
    }

    init(format: inout AudioStreamBasicDescription, sink: (any AudioSink)?) throws {
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw SystemAudioTapError.noFormat }
        self.sink = sink
        channels = Int(format.mChannelsPerFrame)
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        resampler = try Resampler(inputRate: format.mSampleRate)
    }

    var counts: (blocks: Int, frames: Int) { state.withLock { ($0.blocks, $0.frames) } }
    var lastHostTime: UInt64? { state.withLock { $0.lastHostTime == 0 ? nil : $0.lastHostTime } }
    var silentSeconds: Double { state.withLock { $0.silentSeconds } }

    func read(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        let hostTime = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : mach_absolute_time()
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let frames = mixDown(buffers)
        guard frames > 0 else { return }
        let silent = mono.prefix(frames).allSatisfy { $0 == 0 }
        state.withLock { state in
            state.blocks += 1
            state.frames += frames
            state.lastHostTime = hostTime
            if silent {
                if state.silentSince == 0 {
                    state.silentSince = hostTime
                }
                state.silentSeconds = HostTime.seconds(hostTime - state.silentSince)
            } else {
                state.silentSince = 0
                state.silentSeconds = 0
            }
        }
        guard let sink else { return }
        mono.withUnsafeBufferPointer { all in
            resampler.process(UnsafeBufferPointer(rebasing: all.prefix(frames)), hostTime: hostTime) {
                sink.receive($0, hostTime: $1)
            }
        }
    }

    /// Hands the sink what the converter still holds. Called after the
    /// device stopped, when no block can come.
    func finish() {
        guard let sink else { return }
        resampler.finish { sink.receive($0, hostTime: $1) }
    }

    /// The mean of the channels into `mono`; returns the frame count. Unlike
    /// the microphone, the channels of a mix carry the same voices.
    private func mixDown(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let first = buffers.first, first.mData != nil else { return 0 }
        let perBuffer = interleaved ? channels : 1
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int(first.mNumberChannels)))
        guard frames > 0 else { return 0 }
        if mono.count < frames {
            mono = [Float](repeating: 0, count: frames)
        }
        Self.mix(buffers, frames: frames, channelsPerBuffer: perBuffer, into: &mono)
        return frames
    }

    static func mix(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, channelsPerBuffer: Int,
                    into mono: inout [Float]) {
        var total = 0
        for i in 0..<frames {
            mono[i] = 0
        }
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = max(1, Int(buffer.mNumberChannels))
            for channel in 0..<stride {
                for i in 0..<frames {
                    mono[i] += data[i * stride + channel]
                }
            }
            total += stride
        }
        guard total > 1 else { return }
        let scale = 1 / Float(total)
        for i in 0..<frames {
            mono[i] *= scale
        }
    }
}

/// A Core Audio property listener; `remove` takes it off.
private struct Listener {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock

    init?(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, queue: DispatchQueue,
          _ body: @escaping @Sendable () -> Void) {
        self.object = object
        address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        self.queue = queue
        block = { _, _ in body() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
    }

    func remove() {
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

extension HostTime {
    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) / ticksPerSecond
    }

    /// Signed seconds from `start` to `end`.
    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? seconds(end - start) : -seconds(start - end)
    }
}

/// An OSStatus as Core Audio's four letters when it is one ('!hog'), else the number.
func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "\(status)" }
    return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
}

func describe(_ format: AudioStreamBasicDescription) -> String {
    let layout = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "non-interleaved" : "interleaved"
    return "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel)-bit \(layout)"
}
