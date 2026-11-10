# Spike: Perekey as an input method

Not part of the app. Answers one question: can an InputMethodKit layer
replace the retype by Backspace? The report lives outside the repository.

## What is here

| Path | What |
|---|---|
| `Sources/SpikeCore/Composer.swift` | The word logic of the three strategies over a client protocol |
| `Sources/SpikeCore/TextClient.swift` | The client protocol and `BufferClient`, an in-memory field that behaves like `NSTextView` |
| `Sources/PerekeyIMSpike/` | The input method: `IMKServer`, the controller, TIS commands |
| `Sources/imk-harness/` | Types into its own `NSTextView`, `NSSearchField`, `NSSecureTextField` and `WKWebView` |
| `Support/Info.plist` | The input method's keys: connection name, controller class, two modes (en, ru) |
| `scripts/` | `test.sh`, `bundle.sh`, `install.sh` |
| `Sources/PerekeyCore`, `PerekeyInput`, `PerekeyVoiceCore` | Symlinks to the app's sources |

Strategies (`defaults write app.perekey.inputmethod.Spike strategy <name>`):

- `marked` (A): the word is marked text while typed, committed at its end.
- `replace` (B): the method inserts each letter and replaces a word to switch over its range.
- `transparent` (B, transparent): the app types every key itself in the
  method's layout; the method only replaces a word to switch at its end.

## Build and test

```
scripts/test.sh
PEREKEY_MODEL=<dir with en.pklm, ru.pklm> scripts/bundle.sh
```

## Try it (needs a person at the Mac)

1. `scripts/install.sh` copies the bundle to `~/Library/Input Methods` and registers it.
2. System Settings → Keyboard → Text Input → Edit… → + → Russian or English →
   "Perekey IM Spike". `TISEnableInputSource` cannot do this step.
3. Pick "Perekey IM Spike — en" in the input menu.
4. Logs, counts only: `log stream --predicate 'subsystem == "app.perekey.imspike"' --info`.
5. Through the real input method, with the screen unlocked:
   `.build/release/imk-harness run --target textview --strategy replace --words 1000 --rate 30 --model <dir>`
   (`--strategy` must match the defaults key above).
6. Remove: `scripts/install.sh --remove`, then delete the source in System Settings.

Without a person, `imk-harness probe` calls each view's `NSTextInputClient`
directly, as IMK does on the app's side, without the input method process.
