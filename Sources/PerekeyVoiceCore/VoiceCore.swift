// SPDX-License-Identifier: GPL-3.0-or-later

/// Voice logic shared by the app and the voice layer. No system calls and no
/// third-party packages: it builds with and without PEREKEY_VOICE.
public enum VoiceCore {
    /// The speech models take 16 kHz mono audio.
    public static let sampleRate: Double = 16_000
}

/// Whether this Mac can run the speech models: Apple Silicon with macOS 15 or newer.
public enum VoiceHost {
    public static func isSupported(isAppleSilicon: Bool, osMajorVersion: Int) -> Bool {
        isAppleSilicon && osMajorVersion >= 15
    }
}
