# Perekey

Free and open-source automatic keyboard layout switcher for macOS.

Typed `ghbdtn` instead of `привет`? Perekey fixes it as you type, or on a
double Shift. Every shortcut is configurable, including Windows-style ⌥⇧ and ⌃⇧.

> Early development. See [docs/PLAN.md](docs/PLAN.md) for the roadmap (in Russian).

## Build

Requires macOS 14+ and Swift 6 (Xcode or Command Line Tools).

```sh
scripts/test.sh     # run unit tests
scripts/bundle.sh   # build and ad-hoc sign .build/app/Perekey.app
```

## License

[GPL-3.0-or-later](LICENSE).
