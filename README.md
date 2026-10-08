# Perekey

Free and open-source automatic keyboard layout switcher for macOS.

Typed `ghbdtn` instead of `привет`? Perekey fixes it as you type, or when you
press Option. Every shortcut is configurable, including Windows-style ⌥⇧ and ⌃⇧.

> Pre-release: no signed build yet. See [docs/PLAN.md](docs/PLAN.md) for the
> roadmap and [docs/manual-check.md](docs/manual-check.md) for what is still to
> be checked by hand (both in Russian).

## What it does

- **Retype on a shortcut.** Option (or any shortcut) retypes the last word or
  the selection in the other layout; press again to bring it back.
- **Automatic switching.** A language model inside the app decides at the end
  of each word. One Backspace right after a correction undoes it, and Perekey
  remembers the word — the hint near the caret says so and offers "Forget".
- **Honest about code.** Terminals and IDEs are "manual only" by default, games
  are off. Rules per app and per website.
- **Any shortcut.** Presets for a single Shift, Windows ⌥⇧ / ⌃⇧, ⌘⇧, two
  separate keys, Caps Lock; or record your own, with conflict warnings.
- **Never in passwords.** Password fields, Secure Input, password-like strings
  and captcha-like random strings are left alone.
- **Extras.** Change case, transliterate, paste without formatting, sounds.
- **Private.** Typed text stays in memory. The only network request is the
  update check, and it can be turned off (see below).

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

## Build

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Commits need a DCO sign-off (`git commit -s`).

## License

[GPL-3.0-or-later](LICENSE).
