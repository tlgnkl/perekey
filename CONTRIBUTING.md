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
| `scripts/bundle.sh` | Build and sign `.build/app/Perekey.app`. |

Start the app with `open .build/app/Perekey.app`, not by running the binary.
macOS (TCC) attributes permissions to the process that launched it, so a binary
started from a terminal asks for the terminal's grants, not the app's.

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
- No network except the update check. No telemetry, no identifiers.

## Code style

- Match the surrounding code.
- Every new file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` (`#` in shell scripts).

## Tests

New logic comes with unit tests. A bug fix comes with a test that fails without the fix.
`scripts/test.sh` must pass; CI runs it, plus the benchmark.

## DCO sign-off

Every commit needs a `Signed-off-by:` line with the same email as the commit author
([Developer Certificate of Origin](https://developercertificate.org/)). Use `git commit -s`.
Forgot? `git rebase --signoff main`, then force-push your branch. CI checks it.

## Dictionaries

Word lists will live as plain text in `data/<language>/` and change through pull
requests. CI will rebuild the model and run the classifier corpus. This arrives with stage 2.

## Reporting problems

Use the issue templates. Report security problems privately: see [SECURITY.md](SECURITY.md).
