<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="">
</p>

<h1 align="center">Perekey</h1>

<p align="center">
  Free and open-source automatic keyboard layout switcher for macOS, with voice input.<br>
  Typed <code>ghbdtn</code> instead of <code>привет</code>? Perekey fixes it as you type, or when you press Option. Or say it: the text lands at the cursor.
</p>

<p align="center">
  <a href="https://github.com/tlgnkl/perekey/releases/latest/download/Perekey.dmg"><img src="https://img.shields.io/badge/Download_for_macOS-5E5CE6?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS"></a>
</p>

<p align="center">
  <a href="https://github.com/tlgnkl/perekey/releases/latest"><img src="https://img.shields.io/github/v/release/tlgnkl/perekey?label=version&color=5E5CE6" alt="Latest version"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-555" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple_Silicon_%2B_Intel-555" alt="Apple Silicon and Intel">
  <a href="https://github.com/tlgnkl/perekey/actions/workflows/ci.yml"><img src="https://github.com/tlgnkl/perekey/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/tlgnkl/perekey?color=555" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="https://tlgnkl.github.io/perekey/">Website</a> ·
  <a href="CHANGELOG.md">What's new</a> ·
  <a href="https://github.com/tlgnkl/perekey/releases">All releases</a> ·
  <a href="README.ru.md">По-русски</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hint-corrected-dark.png">
    <img src="docs/images/hint-corrected-light.png" width="384" alt="Hint near the caret: ghbdtn → привет, with an Undo button">
  </picture>
</p>

## Install

1. [Download `Perekey.dmg`](https://github.com/tlgnkl/perekey/releases/latest/download/Perekey.dmg)
   from the latest release.
2. Open the DMG and drag Perekey to Applications.
3. Start Perekey from Applications.
4. Allow Accessibility and Input Monitoring when Perekey asks. Without them it
   cannot see keystrokes or replace a word.

Needs macOS 14 or later, on Apple Silicon or Intel. Voice input, transcripts
and call recording need Apple Silicon and macOS 15 or later; on any other Mac
Perekey switches layouts as before and the Voice tab says why voice is off.

Or with Homebrew:

```sh
brew install --cask tlgnkl/tap/perekey
```

> [!IMPORTANT]
> Builds are not signed by Apple yet, so macOS blocks the first launch.
> - **macOS 15 and later:** open Perekey once, close the warning, then go to
>   System Settings → Privacy & Security and click **Open Anyway**.
> - **macOS 14:** Control-click Perekey in Applications, choose **Open**, then
>   **Open** again.

**Updates.** Perekey checks for a new version once a day and asks before it
installs. Each release lists its changes in [CHANGELOG.md](CHANGELOG.md) and on
the [releases page](https://github.com/tlgnkl/perekey/releases). Every DMG
comes with a `.sha256` file:
`shasum -a 256 -c Perekey-<version>.dmg.sha256`.

## What it does

- **Retype on a shortcut.** Option (or any shortcut) retypes the last word or
  the selection in the other layout; press again to bring it back.
- **Automatic switching.** A language model inside the app decides at the end
  of each word. One Backspace right after a correction undoes it. Undo the
  same word a few times and Perekey asks whether to leave it alone in this
  app or everywhere.
- **Typo fixes.** One-key typos such as `прривет` are fixed with the same undo.
- **Languages.** Russian, English, Ukrainian and Belarusian, in any mix of
  installed layouts.
- **Honest about code.** Terminals and IDEs are "manual only" by default, games
  are off. Rules per app and per website.
- **Any shortcut.** Presets for a single Shift, Windows ⌥⇧ / ⌃⇧, ⌘⇧, two
  separate keys, Caps Lock, or the macOS shortcut you already use (⌃Space,
  ⌘Space, 🌐); or record your own, with conflict warnings.
- **Never in passwords.** Password fields, Secure Input, password-like strings
  and captcha-like random strings are left alone.
- **Extras.** Change case, transliterate, paste without formatting, sounds.
- **Voice input.** Tap the right Option key, say a phrase, tap again, and the
  text lands at the cursor, in any app. Russian, English and Ukrainian work in
  one phrase. See "Voice input" below.
- **Transcripts and call recording.** Turn an audio or video file into text
  with timestamps and speakers, or record a call (your microphone and the
  sound of an app, as two tracks). See "Transcripts and calls" below.
- **Private.** Typed text is never saved. Speech models run on your Mac. The
  network is used to check for updates, and for what you start yourself:
  downloading a speech model and sending text or sound to a server you set up.
  Nothing is sent before that (see "Network").

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-shortcuts-dark.png">
    <img src="docs/images/settings-shortcuts-light.png" width="720" alt="Shortcuts settings: presets Shift, Double Shift, Option + Shift, Control + Shift, Command + Shift and Two keys">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hint-learned-dark.png">
    <img src="docs/images/hint-learned-light.png" width="384" alt="Hint after an undo: Remembered “дедлайн”, with a Forget button">
  </picture>
</p>

## Voice input

Needs Apple Silicon and macOS 15 or later. Turn it on in Settings → Voice; the
first launch after the update asks first.

- **How.** Tap the right Option key, speak, tap again. Retyping moves to the
  left Option, or pick another key for voice and keep Option as it was. A
  shortcut with a modifier, such as ⌥Space, also works as hold-to-talk.
- **Models.** Parakeet (Russian, Ukrainian, English and 22 more European
  languages) and Whisper (99 languages, Belarusian included). They are not in
  the app: Settings → Voice has a Download button, and nothing is fetched
  before you press it. They run on your Mac, so with a local model voice
  makes no network requests.
- **Text.** Filler words go, and a dictionary of your names and terms helps
  the recognizer. Recent dictations are kept for 7 days (shorter, or off, in
  Settings), and the audio is kept only if you tick “Keep the audio of
  dictations”.
- **Modes.** A mode decides what happens to the text after recognition: as
  said, a clean draft, a short message, an email, a terminal mode that adds
  nothing and never presses Enter, a translation into English, or your own.
  Perekey picks the mode by the site, then by the app.
- **Terminals.** In a terminal the text is typed instead of pasted, so a tool
  such as Claude Code shows a long dictation in full; Settings → Apps sets
  paste or typing per app.
- **Cloud, only by your key.** A mode can send the text to an LLM (OpenAI,
  Groq, Ollama, LM Studio, any OpenAI-compatible server), and speech
  recognition can run on OpenAI or Groq. All of it is off until you add the
  address and key. The key stays in the Keychain, and Perekey asks before the
  first request to each server.
- **Where it keeps quiet.** In password fields and while macOS hides the keys
  (Secure Input), voice does not listen.

## Transcripts and calls

- **Transcripts window.** Drop an audio or video file in. Perekey transcribes
  it on this Mac with timestamps and, if you ask, speakers. Click a phrase to
  hear it, search inside the text, and export to TXT, Markdown, SRT, VTT or
  JSON.
- **Summary and meeting minutes.** A finished transcript becomes a summary or
  meeting minutes. By default a language model on this Mac writes them (Ollama
  or LM Studio). A cloud model is used only if you pick it, and Perekey first
  asks to send the transcript: it holds the other people’s words too.
- **Record a call.** From the menu. Your microphone is “Me”; the sound of one
  app, or of the whole Mac, is “Others”. Each is a separate track, so the
  transcript says who spoke. A crash, or a switch to headphones, does not stop
  the recording. In many countries recording a conversation needs the consent
  of the people in it: warn them that you are recording.
- **Permissions.** Microphone, and “System Audio Recording” in System Settings →
  Privacy & Security for the other side of a call. Perekey asks the first time.
- **What stays.** Recordings and transcripts stay on this Mac until you delete
  them. Call audio is kept always (the default), for 30 days, or deleted after
  transcription. They are excluded from Time Machine unless you turn that on.

## What is stored

Typed text is never saved: the word you are typing lives in memory. Perekey
keeps four files in `~/Library/Application Support/Perekey/`:

- `settings.json`: settings and your word lists ("Mine", "Learned",
  "Always fix"), with dates, undo counts and app IDs, and the words you
  undid but Perekey has not asked about yet. These are words you chose or
  undid, so they are text you typed; the lists are in Settings → Words.
- `statistics.json`: only with "Count corrections" on. Counts per day and kind
  of correction, and how many you undid. No words, no apps.
- `languages.json`: how many words of each language you type in each app, by
  app ID. No words. Counts for websites stay in memory and are gone on quit.
- `learning-journal.json`: the last 500 undos and answers about learning a
  word, to tune when Perekey asks: how you undid, what you typed next (as a
  kind: space, punctuation), the app ID and the time. No words.

Settings → Privacy erases the counts.

Voice adds its own files in the same folder: dictation history (7 days by
default, can be off), your dictionary and modes, and, if you use them,
recordings and transcripts. API keys for a cloud mode live in the Keychain,
not in a file. The speech models are in the same folder too, and Settings →
Voice deletes them.

## Network

Perekey checks for updates at one address:

    https://tlgnkl.github.io/perekey/appcast.xml

Voice adds two more reasons for the network, and both start with you: pressing
Download on a speech model (`huggingface.co` and its download servers), and
using a mode or recognition on a server you set up (the address you typed;
`localhost` and your local network for Ollama and LM Studio). With voice off, or
with local models only, nothing but the update check leaves your Mac.

- **What is sent:** a plain HTTP GET of that file, at most once a day, with
  Sparkle's user agent (`Perekey/<version> Sparkle/<version>`). No query
  parameters, no system profile, no device or install ID. What you type never
  leaves your Mac.
- **When you install an update:** after you click Install, the DMG downloads
  from GitHub Releases (`github.com`, which redirects to
  `release-assets.githubusercontent.com`). The "Version History" button opens
  the release page in your browser.
- **Turning it off:** Settings → General → turn off "Check for updates
  automatically". Perekey then makes no network requests unless you click
  "Check Now".
- **Organizations:** a configuration profile with `UpdatesDisabled = true`
  forbids even manual checks. Together with `VoiceDisabled`, or with
  `VoiceCloudDisabled` and `VoiceModelDownloadsDisabled`, Perekey makes no
  network requests at all. See
  [docs/managed-preferences.md](docs/managed-preferences.md) (in Russian).

To verify, allow only these hosts in Little Snitch or LuLu and watch the rest.

## Automation

Perekey answers to a few harmless commands, by link or by AppleScript. Nothing
here reads or changes your word lists, and a link that is not exactly one of
these does nothing.

| Link | Effect |
|---|---|
| `perekey://pause?minutes=30` | Pause for 1–1440 minutes (60 without `minutes`) |
| `perekey://resume` | End the pause |
| `perekey://autoswitch?on=0` | Turn automatic switching off (`1` on; without `on`, toggle) |
| `perekey://mode?value=manual` | Mode of the app in front: `auto`, `manual` or `off` |

- **Raycast, Alfred, Terminal:** `open perekey://pause?minutes=30`. In Raycast
  or Alfred, add a Quicklink or a "Run script" with that command.
- **Shortcuts:** add the action "Open URLs" with the link.
- **AppleScript:**

      osascript -e 'tell application "Perekey" to pause for 30'
      osascript -e 'tell application "Perekey" to resume'
      osascript -e 'tell application "Perekey" to set autoswitch to false'
      osascript -e 'tell application "Perekey" to set app mode to "manual"'
      osascript -e 'tell application "Perekey" to get current layout name'
      osascript -e 'tell application "Perekey" to get paused'

  Starting Perekey this way launches it if it is not running.

## Acknowledgements

Voice input stands on open models and libraries. The models run on your Mac.

- **Speech recognition.** NVIDIA Parakeet TDT 0.6B v3 (NVIDIA) and Parakeet Ultra (a
  post-training of it by Moondream), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/),
  converted to Core ML by Fluid Inference. The converted files are modified.
- **Whisper.** OpenAI Whisper large-v3 turbo, MIT License, as Core ML files from
  [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml);
  the tokenizer files come from [openai/whisper-large-v3](https://huggingface.co/openai/whisper-large-v3)
  (Apache License 2.0).
- **Voice activity.** Silero VAD, MIT License, converted to Core ML by Fluid
  Inference.
- **Speakers.** Speaker diarization uses the offline pipeline of
  [FluidAudio](https://github.com/FluidInference/FluidAudio) with models from
  [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml)
  ([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)): pyannote
  segmentation-community-1 (pyannote.audio), WeSpeaker ResNet34 embeddings
  (WeSpeaker), VBx clustering and PLDA (BUT Speech@FIT), converted to Core ML
  and changed by Fluid Inference.
- **Libraries.** [FluidAudio](https://github.com/FluidInference/FluidAudio)
  (Apache License 2.0), with fastcluster (BSD 2-Clause, Daniel Müllner and
  Google) and a Japanese text frontend ported from Misaki (Apache License 2.0),
  cutlet and Convert-Numbers-to-Japanese (MIT);
  [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (MIT License),
  with parts derived from swift-transformers by Hugging Face (Apache License 2.0).
- **Updates.** [Sparkle](https://sparkle-project.org) (MIT License), with
  bsdiff by Colin Percival, sais-lite by Yuta Mori, Ed25519 by Orson Peters and
  SUSignatureVerifier by Mark Hamlin; their terms are in Sparkle's LICENSE file.
  The same list is in Perekey → About.

## Build from source

Runs on macOS 14+ (voice: Apple Silicon and macOS 15+). Building needs the macOS 26 SDK and Swift 6.2+ (Xcode 26 or
its Command Line Tools): the app uses Liquid Glass where available.

```sh
scripts/test.sh       # run unit tests
scripts/bench.sh      # benchmark the input logic (BENCH_BASE=<ref> compares)
scripts/dev-cert.sh   # once: create a local "Perekey Dev" signing identity
scripts/bundle.sh     # build and sign .build/app/Perekey.app

# Debug builds render the settings panes to PNG without a screen:
PEREKEY_SNAPSHOT=/tmp/shots .build/debug/Perekey
```

Releases are built with voice input: `PEREKEY_VOICE=1 scripts/bundle.sh`
builds the same app in `.build/voice` (`Package.swift` explains the flag). A
build without the flag has no voice, no FluidAudio and no WhisperKit.

Without `dev-cert.sh` the app is signed ad hoc, and macOS forgets the
Accessibility permission after every rebuild.

The roadmap is in [docs/PLAN.md](docs/PLAN.md), and what is still checked by
hand is in [docs/manual-check.md](docs/manual-check.md) (both in Russian).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Commits need a DCO sign-off (`git commit -s`).
Found a false switch or an app where Perekey misbehaves?
[Open an issue](https://github.com/tlgnkl/perekey/issues/new/choose): there are
forms for both. Security problems go through [SECURITY.md](SECURITY.md).

## License

[GPL-3.0-or-later](LICENSE).
