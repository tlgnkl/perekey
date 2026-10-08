# Perekey

Free and open-source automatic keyboard layout switcher for macOS.

Typed `ghbdtn` instead of `привет`? Perekey fixes it as you type, or on a
double Shift. Every shortcut is configurable, including Windows-style ⌥⇧ and ⌃⇧.

> Early development. See [docs/PLAN.md](docs/PLAN.md) for the roadmap (in Russian).

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

## License

[GPL-3.0-or-later](LICENSE).
