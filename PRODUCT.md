# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app (SwiftUI + AppKit), macOS 14+. Design mockups are built as
HTML that imitates the native app; the shipped product is not a web app.

## Stack

Product: Swift 6, SwiftPM, SwiftUI `MenuBarExtra` + `Settings`, AppKit where
needed. Mockups: a single static HTML page (no framework), one interactive
macOS desktop scene.

## Users

- People who write in both Russian and English every day: messengers, mail,
  documents. They type a word in the wrong layout many times a day.
- Developers: they switch between code, terminals and chats, and suffer most
  from false automatic switches inside code.
- People who moved from Windows and expect Alt+Shift / Ctrl+Shift.
- Former Punto Switcher users: its Mac build is Intel-only and stops working
  without Rosetta.

## Product Purpose

Perekey is a free, open-source automatic keyboard layout switcher for macOS.
It fixes text typed in the wrong layout (`ghbdtn` → `привет`) as you type, or
on a shortcut, and switches layouts with any shortcut the user is used to.
Success: the user stops thinking about layouts, and never has to clean up
after Perekey.

## Positioning

- **Predictable:** one Backspace right after an automatic switch undoes it,
  and Perekey remembers the word. Learning is visible: the hint names the
  remembered word and offers "Forget".
- **Honest about code:** terminals and IDEs default to manual-only switching.
- **Verifiable privacy:** open code (GPL-3.0-or-later), typed text stays in
  memory only, the only network request is the update check, no device or
  install identifiers.
- Any shortcut on any action: Shift, Option, ⌥⇧, ⌃⇧, ⌘⇧, right ⌘ / right ⌥.

## Operating Context

- Lives in the menu bar, no Dock icon. Mostly invisible: the user meets it
  when it switches a word, when they undo, and when they change a setting.
- Requires Accessibility and Input Monitoring permissions; onboarding must
  earn that trust.
- Works across every app: browsers, messengers, editors, terminals.

## Capabilities and Constraints

- Manual retype of the last word or selection (default: Option).
- Layout switch by shortcut (default: Shift), presets for Windows habits.
- Automatic switching with undo and visible learning from undos ("Learned"
  list, "Forget" in the hint, a switch to turn learning off).
- Per-app modes: auto / manual only / off; per-app default layout; games off
  by default.
- Word exceptions, password-field and Secure Input awareness; password-like
  strings and captcha-like random strings are never switched. The menu bar
  capsule names why Perekey is paused.
- Typo correction for Russian and English (off by default until it meets the
  quality bar), with the same one-Backspace undo.
- Later: ё-fication, double-caps and accidental Caps Lock fix, abbreviations,
  switch and correction sounds, paste without formatting.
- Russian and English UI. Layouts: Russian and English first.
- No subscription, no telemetry, no sending typed words anywhere. The update
  check can be turned off; the language model ships inside app updates.

## Brand Commitments

- Name: Perekey. Wordmark not designed yet.
- Must feel like a native Mac app, not a website (user's binding constraint).
- Must not resemble Caramba Switcher's branding.

## Evidence on Hand

- No users, testimonials, metrics or screenshots yet. Do not invent them.
- Roadmap: `docs/PLAN.md`.

## Product Principles

1. Never surprise the user: every automatic action is visible and undoable.
2. Stay out of the way: the best session is one where Perekey is not noticed.
3. Earn trust explicitly: say what is seen, what is stored, what is sent.
4. Respect habits: the user's muscle memory wins over our defaults.
