// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import ServiceManagement

/// "Launch at login" through `SMAppService.mainApp`.
///
/// The service needs a real `.app` bundle. `swift run` starts a bare executable,
/// so the toggle is off there. A failed `register()` keeps its error in
/// `lastError`, and the menu shows it instead of hiding the failure.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status
    private(set) var lastError: String?

    /// Whether this process runs from a `.app` bundle.
    let isBundled: Bool

    @ObservationIgnored private let service: SMAppService?

    init(service: SMAppService = .mainApp, bundle: Bundle = .main) {
        self.service = service
        isBundled = bundle.bundleURL.pathExtension == "app"
        status = service.status
    }

    #if DEBUG
    /// Snapshot helper: shows a status without touching the system.
    init(previewStatus: SMAppService.Status, error: String? = nil, bundled: Bool = true) {
        service = nil
        isBundled = bundled
        status = previewStatus
        lastError = error
    }
    #endif

    /// On, or waiting for the user's approval in System Settings.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    /// The toggle works only in an app bundle. The status cannot tell this:
    /// macOS reports `.notFound` also for an installed app that has never
    /// registered, and only `register()` gets it out of that state.
    var isAvailable: Bool { isBundled }

    func setEnabled(_ on: Bool) {
        guard let service else { return }
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        status = service.status
    }

    /// Re-reads the status: the user may change it in System Settings.
    func refresh() {
        if let service { status = service.status }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
