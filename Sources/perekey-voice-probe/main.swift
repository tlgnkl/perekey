// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dev tool: downloads, loads and measures speech models outside the app.

import PerekeyVoice
import PerekeyVoiceCore

print("perekey-voice-probe: \(VoiceEngines.linked.count) engines, \(Int(VoiceCore.sampleRate)) Hz")
