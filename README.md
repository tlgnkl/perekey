# Perekey

Free and open-source automatic keyboard layout switcher for macOS.

Typed `ghbdtn` instead of `привет`? Perekey fixes it as you type, or on a
double Shift. Every shortcut is configurable, including Windows-style ⌥⇧ and ⌃⇧.

> Early development. See [docs/PLAN.md](docs/PLAN.md) for the roadmap (in Russian).

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

## Build

Requires macOS 14+ and Swift 6 (Xcode or Command Line Tools).

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
