// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import ServiceManagement

/// "Launch at login" through `SMAppService.mainApp`.
///
/// The service needs a real, signed `.app` bundle. From `swift run` the status is
/// `.notFound` and `register()` throws; the error is kept in `lastError` and the
/// menu shows it instead of hiding the failure.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status
    private(set) var lastError: String?

    @ObservationIgnored private let service: SMAppService?

    init(service: SMAppService = .mainApp) {
        self.service = service
        status = service.status
    }

    #if DEBUG
    /// Snapshot helper: shows a status without touching the system.
    init(previewStatus: SMAppService.Status, error: String? = nil) {
        service = nil
        status = previewStatus
        lastError = error
    }
    #endif

    /// On, or waiting for the user's approval in System Settings.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    /// The toggle works only in an installed app.
    var isAvailable: Bool { status != .notFound }

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
