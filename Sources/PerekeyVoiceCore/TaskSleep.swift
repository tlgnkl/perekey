// SPDX-License-Identifier: GPL-3.0-or-later

/// `Task.sleep(for:)` as a value: the default of the `sleep` parameters that
/// tests replace with a clock of their own.
///
/// Use it instead of writing `{ try await Task.sleep(for: $0) }` as the
/// default. The default argument of a public function is compiled into every
/// module that calls it, so a closure there gets one copy per module, each a
/// weak definition under the same name, and the copies need not be the same
/// code. SwiftPM links the modules into one binary. With Swift 6.3 the linker
/// kept the async context size of the test module's copy (128 bytes) and the
/// code of PerekeyVoiceCore's (which needs 144): the unload timer of
/// `ModelResidency` wrote past its context, and the process aborted with
/// "freed pointer was not the last allocation". A global is defined once,
/// here, and a default argument that reads it compiles no async code into the
/// caller.
public let taskSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
