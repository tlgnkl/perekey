# Packaging

## Homebrew tap

`homebrew/perekey.rb` is a cask template for the own tap `tlgnkl/homebrew-tap`.
Users install with:

    brew install --cask tlgnkl/tap/perekey

To publish:

1. Create the public repository `tlgnkl/homebrew-tap` once.
2. After each release, copy `perekey.rb` to `Casks/perekey.rb` there.
3. Set `version` to the release number (no `v`).
4. Set `sha256` to the content of `Perekey-<version>.dmg.sha256` from the release.
5. Run `brew audit --cask --online tlgnkl/tap/perekey` and `brew install --cask` locally.
6. Commit and push the tap.

The app updates itself through Sparkle (`auto_updates true`), so the cask only
has to move forward when a new version should be installable from scratch.
Until the DMG is Developer ID signed and notarized, Gatekeeper asks the user to
approve the app on first launch.
