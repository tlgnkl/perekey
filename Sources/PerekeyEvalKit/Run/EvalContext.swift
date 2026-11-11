// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where the commands write and what they read from the environment. A
/// test sets both for the commands it runs, so that it sees all they print
/// (the proof that a personal set leaves no word in the output) without a
/// redirect of the process's streams.
public enum EvalContext {
    /// What a command printed.
    public final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var out = "", err = ""

        public init() {}

        public var stdout: String { lock.withLock { out } }
        public var stderr: String { lock.withLock { err } }

        func write(_ text: String, error: Bool) {
            lock.withLock {
                if error { err += text } else { out += text }
            }
        }
    }

    @TaskLocal public static var capture: Capture?
    @TaskLocal public static var environment: [String: String]?

    static var env: [String: String] { environment ?? ProcessInfo.processInfo.environment }

    /// Like `print`.
    static func out(_ text: String, terminator: String = "\n") {
        if let capture {
            capture.write(text + terminator, error: false)
        } else {
            print(text, terminator: terminator)
        }
    }

    /// A line on the error stream.
    static func err(_ text: String) {
        if let capture {
            capture.write(text + "\n", error: true)
        } else {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
    }
}
