// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

/// Waits for a condition the test names, not for a number of turns of the
/// scheduler. Fails the test when the condition is still false at the deadline.
@MainActor
func waitUntil(_ what: String, timeout: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: () -> Bool) async
{
    let deadline = ContinuousClock.now + .seconds(timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Still waiting after \(timeout) s: \(what)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
