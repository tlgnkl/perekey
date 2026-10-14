# Changelog

What changed in each Perekey release, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Downloads are on the
[releases page](https://github.com/tlgnkl/perekey/releases).

Each release gets its notes from its section here (`scripts/release-notes.sh`),
so write for people who use the app: what they can now do, what works
differently, what was fixed.

## [Unreleased]

### Added

- **Keep the macOS shortcut.** If you switch layouts with ⌃Space, ⌘Space or
  the 🌐 key, pick “As now in macOS”: Perekey leaves switching to macOS and
  only adds Option to retype the word. Onboarding picks it for you when you
  have changed that shortcut yourself.
- **Your own switch shortcut in onboarding.** Click the keys of “Switch layout”
  and press any shortcut, such as ⌥Space.

### Changed

- **Words joined by a slash are fixed one by one.** In “доходы/расходы”,
  “менеджер/CEO” or “приход/расход” automatic switching judges each word on its
  own: “ghbdtn/vbh” becomes “привет/мир”, and “привет/цщкдв” becomes
  “привет/world”. Addresses and code such as “github.com/user” or
  “~/docs” stay as typed. Short parts (“B/C”) and parts with capitals inside
  (“UX/UI”) stay as they are too. On Russian – PC, where “/” is Shift+\,
  the token is judged whole, as before.
- **Option retypes the part after a slash.** In “менеджер/сущ” the first
  press gives “менеджер/ceo” and leaves the word before the slash alone.
  Press again to put it back, and a third time to retype the whole word.
  If the word before the slash is in the wrong layout too, the first press
  retypes everything, as before. With phrase retype off, every press
  toggles only the part after the slash.
- **Conflict warnings read your Mac.** Perekey warns about Spotlight or the
  macOS input switch only when that shortcut really does it on this Mac.
- **Paste without formatting leaves passwords to your password manager.**
  If you copied a password (from 1Password, for example), Perekey no longer
  puts it back on the clipboard after the paste: the clipboard is left empty,
  so your password manager's own clearing still works. Anything else you
  copied comes back as before. The plain text Perekey pastes stays on this
  Mac and is not sent to your iPhone or iPad.

### Fixed

- **The hint stays by the cursor in terminals.** In terminals built on
  xterm.js (Orca, the VS Code terminal) the correction hint appeared in the
  top right corner of the screen. It now shows next to the line you type in.
- **Switching works in Telegram Lite.** In Telegram Lite and Telegram Desktop
  Perekey noticed the wrong layout but never fixed the word, neither by itself
  nor with Option. The native Telegram for macOS was not affected.

## [0.1.1] - 2026-10-12

### Fixed

- **Settings open again.** Settings… in the menu did nothing on macOS 14 and
  later. It opens the Settings window now, in front of other apps.
- **No window at launch.** Perekey no longer opens Settings by itself when it
  starts.
- **Launch at login** can now be turned on. In 0.1.0 the switch stayed grey
  with "Works in the installed app only" even in the installed app, because
  macOS reports an app that has never been added to Login Items as unknown.
- **Asking for Accessibility.** macOS no longer shows its access alert at
  launch and again every second, before Perekey has said why it needs the
  access. Only the button in the welcome window asks now.
- **The welcome window comes back.** Once you switch Perekey on in System
  Settings, the window returns to the front by itself. Before, it stayed under
  System Settings, and a menu bar app has no Dock icon to bring it back.
- **Starting without access.** If Perekey starts without access, or loses it,
  it opens the access step instead of doing nothing silently.

## [0.1.0] - 2026-10-11

The first public preview. The DMG is not signed by Apple yet, so macOS asks you
to confirm the first launch (the release notes say how).

### Added

- **Retype on a shortcut.** Option, or any shortcut you pick, retypes the last
  word or the selection in the other layout. Press it again to bring the text
  back.
- **Automatic switching.** A language model inside the app checks each word as
  you finish it and fixes `ghbdtn` → `привет` by itself. One Backspace right
  after a fix undoes it, and Perekey remembers the word.
- **Typo fixes.** One-key typos such as `прривет` are fixed the same way, with
  the same undo. Turn it off in Settings → General.
- **Languages.** Russian, English, Ukrainian and Belarusian, in any mix of
  installed layouts. Perekey loads the language of each layout you have.
- **Shortcut presets.** Shift, Double Shift, ⌥⇧ and ⌃⇧ like on Windows, ⌘⇧,
  two separate keys, Caps Lock, or record your own with conflict warnings.
- **Rules per app and per website.** Auto, manual only or off. Terminals and
  IDEs start as manual only, games as off.
- **Word lists.** "Mine", "Learned" (with how often you undid each word) and
  "Always fix". Export and import in Settings → Words.
- **Hint at the caret.** Shows each fix with Undo, "Forget" for a learned word
  and "Why?" with the reason behind the decision.
- **Menu bar.** A live layout indicator, the latest fixes, pause, and the mode
  of the app in front.
- **Optional statistics.** Corrections per day and kind, with no words stored.
- **Automation.** `perekey://` links and AppleScript commands to pause, resume
  and change modes, for Raycast, Alfred and Shortcuts.
- **Extras.** Change case, transliterate, paste without formatting, sounds.
- **Updates.** Sparkle checks for a new version at most once a day. Turn it
  off in Settings → General; organizations can forbid it with a profile.

### Privacy

- Typed text is never saved. Password fields, Secure Input, password-like and
  captcha-like strings are left alone.
- The only network request is the update check.

[Unreleased]: https://github.com/tlgnkl/perekey/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/tlgnkl/perekey/releases/tag/v0.1.1
[0.1.0]: https://github.com/tlgnkl/perekey/releases/tag/v0.1.0
