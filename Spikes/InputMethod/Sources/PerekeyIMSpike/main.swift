// SPDX-License-Identifier: GPL-3.0-or-later
//
// The spike input method. Without arguments it is the IMK server the system
// starts. With a command it manages its own input sources through TIS:
//
//   PerekeyIMSpike status            every source of this bundle: enabled, selectable, selected
//   PerekeyIMSpike register          TISRegisterInputSource on this bundle
//   PerekeyIMSpike enable|disable    TISEnableInputSource / TISDisableInputSource on every mode
//   PerekeyIMSpike select <mode-id>  TISSelectInputSource

import AppKit
import Carbon
import InputMethodKit

func sources() -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: Bundle.main.bundleIdentifier ?? "app.perekey.inputmethod.Spike"]
    return TISCreateInputSourceList(filter as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource] ?? []
}

func property(_ source: TISInputSource, _ key: CFString) -> Any? {
    TISGetInputSourceProperty(source, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
}

func status() {
    let all = sources()
    print("sources: \(all.count)")
    for source in all {
        let id = property(source, kTISPropertyInputSourceID) as? String ?? "?"
        let type = property(source, kTISPropertyInputSourceType) as? String ?? "?"
        let enabled = (property(source, kTISPropertyInputSourceIsEnabled) as? Bool) ?? false
        let selectable = (property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool) ?? false
        let selected = (property(source, kTISPropertyInputSourceIsSelected) as? Bool) ?? false
        print("\(id) type=\(type) enabled=\(enabled) selectable=\(selectable) selected=\(selected)")
    }
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "status":
    status()
case "register":
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    print("TISRegisterInputSource: \(status)")
case "enable", "disable":
    for source in sources() {
        let id = property(source, kTISPropertyInputSourceID) as? String ?? "?"
        let status = arguments.first == "enable" ? TISEnableInputSource(source) : TISDisableInputSource(source)
        print("\(arguments.first!) \(id): \(status)")
    }
    status()
case "select":
    guard let wanted = arguments.dropFirst().first,
          let source = sources().first(where: { property($0, kTISPropertyInputSourceID) as? String == wanted })
    else { print("no such source"); exit(1) }
    print("TISSelectInputSource: \(TISSelectInputSource(source))")
case nil:
    let name = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String ?? ""
    let server = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier)
    log.info("server \(name, privacy: .public) up: \(server != nil, privacy: .public)")
    withExtendedLifetime(server) { NSApplication.shared.run() }
default:
    print("usage: PerekeyIMSpike [status | register | enable | disable | select <mode-id>]")
    exit(64)
}
