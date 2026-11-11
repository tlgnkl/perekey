# Contributing to Perekey

Thanks for helping. Perekey is GPL-3.0-or-later. By contributing you agree your
work is licensed the same way, certified by the DCO sign-off below.

## Build and test

Requires macOS 14+ and Swift 6. Command Line Tools are enough; Xcode is not needed.

| Command | Purpose |
|---|---|
| `scripts/test.sh` | Run unit tests. Works around the missing Swift Testing macro plugin on Command Line Tools. Extra arguments go to `swift test`. |
| `scripts/bench.sh` | Benchmark `InputMachine` in release. `BENCH_BASE=<ref>` compares with another commit and fails on a >20 % slowdown. Run it when you touch `PerekeyCore`. |
| `scripts/dev-cert.sh` | Run once. Creates a local self-signed "Perekey Dev" identity. macOS ties Accessibility and Input Monitoring grants to the code signature; an ad-hoc signature changes every build, so the grant is lost after each rebuild. |
| `scripts/bundle.sh` | Build and sign `.build/app/Perekey.app`, with Sparkle embedded in `Contents/Frameworks`. Every build is signed with `Support/Perekey.entitlements`: without its audio input entitlement macOS gives the app no microphone. Signs with "Perekey Dev" when it exists; `SIGN_IDENTITY=-` signs ad hoc, and `SIGN_IDENTITY` with `SIGN_KEYCHAIN` picks another identity. |
| `scripts/release-cert.sh` | Maintainers only, once. Creates the self-signed "Perekey Release" identity that signs releases; see [docs/release.md](docs/release.md). |
| `scripts/appcast.sh` | Write the signed Sparkle appcast for a release DMG. CI runs it; see [docs/release.md](docs/release.md). |

Voice input is in progress and builds only with `PEREKEY_VOICE=1`, in its own
scratch path: `scripts/voice-pins.sh use`, then
`PEREKEY_VOICE=1 swift build --scratch-path .build/voice`. `scripts/test.sh`,
`bundle.sh`, `build-universal.sh` and `snapshot.sh` take the variable and do both
themselves. Speech models load only from the app's own store:
`scripts/check-voice-loaders.sh` fails on the loaders of FluidAudio and WhisperKit.
The pins of the voice build live in `Support/voice/Package.resolved`; the root
`Package.resolved` is ignored by git, so builds without the flag fetch no voice
packages. The flagged scripts copy the pins to the root before they build. Update
them with `scripts/voice-pins.sh update`, never with a bare `swift package update`.

Start the app with `open .build/app/Perekey.app`, not by running the binary.
macOS (TCC) attributes permissions to the process that launched it, so a binary
started from a terminal asks for the terminal's grants, not the app's.

The voice build has hidden checks that need the app's own grants, such as
the microphone: `open -n -W .build/voice/app/Perekey.app --args --voice-check mic`
asks for access, reads the microphone, switches devices and starts and stops it
1000 times. Each check writes its lines to `~/Library/Logs/Perekey/voice-check-<name>.txt`;
`--voice-check help` lists them.

## Recording typing for the measure

The classifier is measured on a corpus (`scripts/eval.sh`). The live measure
replays real typing through the whole `InputMachine` instead
(docs/classifier.md, «Замер на живых сессиях»). The recordings come from a
developer build with the typing recorder in it. A release never has it.

**Build.** `PEREKEY_RECORD=1 scripts/bundle.sh` builds `.build/record/app/Perekey.app`;
with `PEREKEY_VOICE=1` too, `.build/voice-record/app/Perekey.app`. Every line of
the recorder is under `#if PEREKEY_RECORD`. `scripts/check-no-recorder.sh` fails
on a binary that has it: CI runs it on the release build and in `release.yml`,
and checks that it fails on a build with the flag. `PEREKEY_RECORD=1 scripts/test.sh`
tests the recorder, in `.build/record`.

**Turn it on.** The menu of that build has «Typing recording (dev)». It is off
by default and stays as you leave it across launches. While it records, the menu
bar item shows ● rec, whatever its own settings: it cannot be hidden.

**What is recorded.** Every event the machine handles, with what it answered:
keys (key codes, so typed text), layout changes, focus (bundle IDs), clicks,
retypes, corrections with the original and the new word. A segment starts with
the machine's state, settings included: the exceptions, the words learned per
app, the always-fix spellings. A selection is recorded as as many «x» as it had
characters. The model is not recorded, only its languages and options.

**What is never recorded.** While the focus is a password field, while Secure
Input is on, and while the focus is in a password manager (1Password,
Bitwarden, KeePassXC, Keychain Access, Passwords), no event is written: the file
gets one `gap` line instead, and recording goes on from the next quiet point
after it. «Do not record here» in the menu adds the app in front to that list.
Right after an app switch, until Accessibility tells the field, the recorder
does not know a password field yet; such a field turns Secure Input on, and then
no key reaches Perekey at all.

**Where.** `~/Library/Application Support/Perekey/sessions.noindex/`, one file
per launch and per day (`2026-11-10-1.pksession`). The folder is 0700, the
files 0600, both out of Time Machine and Spotlight. A file goes 30 days after
it was last written, at launch. «Erase Recordings…» removes them all, «Show
Recordings in Finder» opens the folder. Never copy them into the repository
(`.gitignore` has `*.pksession`), a log, an issue or a shared folder: they hold
what you typed.

**How it works.** On the tap thread the engine only appends the event and the
output to an array in memory (`RecordingBuffer`); every 256 events or once a
second the array goes to the recorder's own queue (`SessionRecorder`, utility
QoS), which encodes and appends it to the file. No disk on the tap thread. When
the disk falls behind by 16 384 entries, the recording writes `gap(overflow)`
and typing goes on unslowed. The last second before a quit may be lost; the
reader drops a line cut off in the middle. `PEREKEY_RECORD=1 scripts/bench.sh`
times the machine with the buffer on («autoswitch, recording»).

**Read them.** `perekey-eval replay check|words|compare <files> --model <dir>`
(docs/classifier.md, «Команды»). Words show only with `--show-words`, and only in
the terminal.

## Toolchain notes

- Without Xcode the `@State` macro is unavailable. Use `State(initialValue:)`
  or `@Observable`.
- Debug builds can render settings panes to PNG without a screen:
  `PEREKEY_SNAPSHOT=/tmp/shots .build/debug/Perekey`.

## Project layout

- `Sources/PerekeyCore` - pure logic (input machine, word buffer, classifier). No system calls; tested on fakes.
- `Sources/PerekeyInput` - system layer (event tap, Text Input Sources, Accessibility).
- `Sources/Perekey` - the app: menu bar, settings, onboarding.

## Threading rules

1. The event tap callback must be fast: no Accessibility, TIS, pasteboard or disk access in it.
2. Hand that work to another queue and return the event immediately.
3. Touch UI only on the main actor.

## Privacy rules

- Never log typed text. Never write it to disk.
- Log with `privacy: .private`.
- No network except the update check and what the user starts (a speech model download, a server they set up). No telemetry, no identifiers.

## Code style

- Match the surrounding code.
- Every new file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` (`#` in shell scripts).

## Tests

New logic comes with unit tests. A bug fix comes with a test that fails without the fix.
`scripts/test.sh` must pass; CI runs it, plus the benchmark.

## Changelog

A change people will notice in the app gets one line under `[Unreleased]` in
[CHANGELOG.md](CHANGELOG.md), in the section that fits: Added, Changed, Fixed,
Removed. Write what the user can now do, not what the code does. The release
notes are made from this file.

## DCO sign-off

Every commit needs a `Signed-off-by:` line with the same email as the commit author
([Developer Certificate of Origin](https://developercertificate.org/)). Use `git commit -s`.
Forgot? `git rebase --signoff main`, then force-push your branch. CI checks it.

## Dictionaries

Word lists will live as plain text in `data/<language>/` and change through pull
requests. CI will rebuild the model and run the classifier corpus. This arrives with stage 2.

## Reporting problems

Use the issue templates. Report security problems privately: see [SECURITY.md](SECURITY.md).
