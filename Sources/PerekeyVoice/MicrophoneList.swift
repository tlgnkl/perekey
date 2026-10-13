// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio

/// An audio device with input channels.
public struct Microphone: Sendable, Hashable {
    public let id: AudioDeviceID
    /// Stable across launches and reconnects; settings keep this, not `id`.
    public let uid: String
    public let name: String
}

/// The input devices of the Mac, read from CoreAudio on each call.
public enum MicrophoneList {
    /// Devices with at least one input channel, in CoreAudio's order.
    public static func all() -> [Microphone] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let ids: [AudioDeviceID] = array(system, kAudioHardwarePropertyDevices) else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Microphone(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    /// The system input device: the one Sound settings show.
    public static func systemDefault() -> Microphone? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let id: AudioDeviceID = value(system, kAudioHardwarePropertyDefaultInputDevice), id != kAudioObjectUnknown
        else { return nil }
        return all().first { $0.id == id }
    }

    public static func device(uid: String) -> Microphone? {
        all().first { $0.uid == uid }
    }

    /// Whether any process, this one included, has the device's I/O running:
    /// for a microphone, what the orange dot in the menu bar shows.
    public static func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        let running: UInt32? = value(id, kAudioDevicePropertyDeviceIsRunningSomewhere)
        return running.map { $0 != 0 } ?? false
    }

    /// False once the device is unplugged or otherwise gone, before CoreAudio
    /// drops it from the list.
    public static func isAlive(_ id: AudioDeviceID) -> Bool {
        let alive: UInt32? = value(id, kAudioDevicePropertyDeviceIsAlive)
        return alive.map { $0 != 0 } ?? false
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }
}
