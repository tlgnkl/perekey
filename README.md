<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="">
</p>

<h1 align="center">Perekey</h1>

<p align="center">
  Free and open-source automatic keyboard layout switcher for macOS.<br>
  Typed <code>ghbdtn</code> instead of <code>привет</code>? Perekey fixes it as you type, or when you press Option.
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

Needs macOS 14 or later, on Apple Silicon or Intel.

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
  of each word. One Backspace right after a correction undoes it, and Perekey
  remembers the word — the hint near the caret says so and offers "Forget".
- **Typo fixes.** One-key typos such as `прривет` are fixed with the same undo.
- **Languages.** Russian, English, Ukrainian and Belarusian, in any mix of
  installed layouts.
- **Honest about code.** Terminals and IDEs are "manual only" by default, games
  are off. Rules per app and per website.
- **Any shortcut.** Presets for a single Shift, Windows ⌥⇧ / ⌃⇧, ⌘⇧, two
  separate keys, Caps Lock; or record your own, with conflict warnings.
- **Never in passwords.** Password fields, Secure Input, password-like strings
  and captcha-like random strings are left alone.
- **Extras.** Change case, transliterate, paste without formatting, sounds.
- **Private.** Typed text is never saved. Only your settings and word lists
  are kept, on this Mac (see "What is stored"). The only network request is the
  update check, and it can be turned off (see below).

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

## What is stored

Typed text is never saved: the word you are typing lives in memory. Perekey
keeps three files in `~/Library/Application Support/Perekey/`:

- `settings.json`: settings and your word lists ("Mine", "Learned",
  "Always fix"), with dates and undo counts. These are words you chose or
  undid, so they are text you typed; the lists are in Settings → Words.
- `statistics.json`: only with "Count corrections" on. Counts per day and kind
  of correction, and how many you undid. No words, no apps.
- `languages.json`: how many words of each language you type in each app, by
  app ID. No words. Counts for websites stay in memory and are gone on quit.

Settings → Privacy erases the counts.

## Network

Perekey talks to one address, and only to check for updates:

    https://tlgnkl.github.io/perekey/appcast.xml

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
  forbids even manual checks, and Perekey makes no network requests at all. See
  [docs/managed-preferences.md](docs/managed-preferences.md) (in Russian).

To verify, allow only this host in Little Snitch or LuLu.

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

## Build from source

Runs on macOS 14+. Building needs the macOS 26 SDK and Swift 6.2+ (Xcode 26 or
its Command Line Tools): the app uses Liquid Glass where available.

```sh
scripts/test.sh       # run unit tests
scripts/bench.sh      # benchmark the input logic (BENCH_BASE=<ref> compares)
scripts/dev-cert.sh   # once: create a local "Perekey Dev" signing identity
scripts/bundle.sh     # build and sign .build/app/Perekey.app

# Debug builds render the settings panes to PNG without a screen:
PEREKEY_SNAPSHOT=/tmp/shots .build/debug/Perekey
```

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
