// SPDX-License-Identifier: GPL-3.0-or-later

import ApplicationServices
import Foundation
import os
import PerekeyCore
import Testing
@testable import PerekeyInput

// The test runner has no Accessibility permission, so these tests check that
// nothing crashes or hangs without it; AX itself is checked by hand in the app.

struct SecureInputTests {
    private let uid: uid_t = 501

    @Test func ownerPIDOfCurrentUserSession() {
        let sessions: [[String: Any]] = [
            ["kCGSSessionUserIDKey": 502, "kCGSSessionOnConsoleKey": true, "kCGSSessionSecureInputPID": 111],
            ["kCGSSessionUserIDKey": 501, "kCGSSessionOnConsoleKey": false, "kCGSSessionSecureInputPID": 222],
        ]
        #expect(SecureInput.ownerPID(inConsoleUsers: sessions, uid: uid) == 222)
    }

    @Test func ownerPIDPrefersSessionOnConsole() {
        let sessions: [[String: Any]] = [
            ["kCGSSessionUserIDKey": 501, "kCGSSessionOnConsoleKey": false, "kCGSSessionSecureInputPID": 111],
            ["kCGSSessionUserIDKey": 501, "kCGSSessionOnConsoleKey": true, "kCGSSessionSecureInputPID": 222],
        ]
        #expect(SecureInput.ownerPID(inConsoleUsers: sessions, uid: uid) == 222)
    }

    @Test func ownerPIDFallsBackToConsoleSession() {
        let sessions: [[String: Any]] = [
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionSecureInputPID": 333],
            ["kCGSSessionUserIDKey": 502, "kCGSSessionSecureInputPID": 444],
        ]
        #expect(SecureInput.ownerPID(inConsoleUsers: sessions, uid: uid) == 333)
    }

    @Test func ownerPIDMissingOrZero() {
        #expect(SecureInput.ownerPID(inConsoleUsers: [], uid: uid) == nil)
        #expect(SecureInput.ownerPID(inConsoleUsers: [["kCGSSessionUserIDKey": 501]], uid: uid) == nil)
        let zero: [[String: Any]] = [["kCGSSessionUserIDKey": 501, "kCGSSessionSecureInputPID": 0]]
        #expect(SecureInput.ownerPID(inConsoleUsers: zero, uid: uid) == nil)
        let wrongType: [[String: Any]] = [["kCGSSessionUserIDKey": 501, "kCGSSessionSecureInputPID": "420"]]
        #expect(SecureInput.ownerPID(inConsoleUsers: wrongType, uid: uid) == nil)
        // Another user's Secure Input is not ours when that user is in the background.
        let other: [[String: Any]] = [["kCGSSessionUserIDKey": 502, "kCGSSessionSecureInputPID": 555]]
        #expect(SecureInput.ownerPID(inConsoleUsers: other, uid: uid) == nil)
    }

    /// Reads the real system. Secure Input may be on (a locked screen keeps it
    /// for loginwindow), so this checks consistency, not a fixed state.
    @MainActor
    @Test func systemReadIsConsistent() {
        let monitor = SecureInputMonitor()
        #expect(monitor.isOn == SecureInput.isEnabled)
        if monitor.isOn {
            #expect(monitor.owner != nil)
        } else {
            #expect(monitor.owner == nil)
            #expect(monitor.ownerName == nil)
        }
        _ = SecureInput.ownerPID()
        #expect(SecureInput.owner(pid: nil) == .unknown)
        #expect(SecureInput.owner(pid: 0) == .unknown)
        #expect(SecureInput.owner(pid: getpid()).name != nil)
    }

    @MainActor
    @Test func monitorReportsChangesOnly() {
        let fake = FakeSystem()
        let monitor = SecureInputMonitor(isOn: { fake.on }, ownerPID: { fake.reads += 1; return getpid() },
                                         observe: false)
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }
        #expect(!monitor.isOn && monitor.owner == nil && fake.reads == 0)

        monitor.refresh()
        fake.on = true
        monitor.refresh()
        monitor.refresh()
        #expect(monitor.isOn)
        #expect(monitor.ownerName != nil)
        fake.on = false
        monitor.refresh()
        #expect(changes == [true, false])
        #expect(monitor.owner == nil)
        #expect(fake.reads == 2) // the registry is read only while on
    }

    @MainActor
    private final class FakeSystem {
        var on = false
        var reads = 0
    }
}

struct FocusObserverTests {
    @Test func subroleDecidesPasswordField() {
        let id = "com.apple.Safari"
        #expect(FocusObserver.focus(bundleID: id, subroleError: .success, subrole: kAXSecureTextFieldSubrole)
            == Focus(bundleID: id, isSecureField: true))
        #expect(FocusObserver.focus(bundleID: id, subroleError: .success, subrole: "AXSearchField")
            == Focus(bundleID: id))
        #expect(FocusObserver.focus(bundleID: id, subroleError: .noValue, subrole: nil) == Focus(bundleID: id))
        #expect(FocusObserver.focus(bundleID: id, subroleError: .cannotComplete, subrole: nil) == .unknown(bundleID: id))
        #expect(!Focus.unknown(bundleID: id).isKnown)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func startAndStopWithoutPermission() async throws {
        let received = OSAllocatedUnfairLock<[Focus]>(initialState: [])
        let observer = FocusObserver { focus in received.withLock { $0.append(focus) } }
        observer.start()
        observer.start() // idempotent
        let thread = try #require(observer.thread)

        try await waitUntil { !received.withLock { $0 }.isEmpty }
        let first = try #require(received.withLock { $0 }.first)
        // Right after start the focused element is never known yet.
        #expect(!first.isKnown)
        if !AXIsProcessTrusted() {
            observer.refresh()
            observer.stop()
            #expect(received.withLock { $0 }.allSatisfy { !$0.isKnown })
        } else {
            observer.stop()
        }
        observer.stop() // idempotent
        #expect(observer.thread == nil)
        try await waitUntil { thread.hasExited }
    }

    @Test func stopBeforeThreadRunsDoesNotHang() async throws {
        let thread = RunLoopThread(name: "test", qualityOfService: .utility)
        let ran = OSAllocatedUnfairLock(initialState: 0)
        thread.perform { ran.withLock { $0 += 1 } }
        thread.stop { ran.withLock { $0 += 10 } }
        thread.perform { ran.withLock { $0 += 100 } } // dropped after stop
        try await waitUntil { thread.hasExited }
        // The thread either started before `stop` (1 + 10) or skipped everything.
        #expect([0, 11].contains(ran.withLock { $0 }))
    }

    /// Polls for up to 5 s. The system parts have no completion to await.
    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met in 5 s")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
