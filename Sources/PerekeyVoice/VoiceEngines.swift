// SPDX-License-Identifier: GPL-3.0-or-later

import FluidAudio
import PerekeyVoiceCore
import WhisperKit

/// The engines the voice layer is built on. Referencing them keeps both
/// packages compiled and linked into the app until the engines use them.
public enum VoiceEngines {
    public static let linked: [Any.Type] = [AsrManager.self, VadManager.self, DiarizerManager.self, WhisperKit.self]
}
