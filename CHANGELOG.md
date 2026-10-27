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

- **Dictation that was not saved.** When a dictation goes into a field Perekey
  cannot see (Electron apps, or no Accessibility), the menu now shows it at the
  top of «Recent dictations» with the note that it is not saved, and «Copy» and
  «Paste again» get the text back after the HUD is gone. Only the latest one is
  kept, in memory: it is not written to disk, and it goes away when a newer
  dictation is saved, on «Clear history» and when Perekey quits. Password
  fields, excluded apps and a switched-off history never show anything.
- **Search in Settings.** A field above the sections: type a word and the
  sections without it dim, and the others show how many rows match. Return
  goes through the matches and opens each row with a highlight; clicking a
  section shows its first match; Escape clears the field. It finds «ё» as
  «е», ignores case, and from five letters it forgives an ending («пароль»
  finds «паролей»). It searches the names of rows and groups in your language
  and in English, not the apps, sites and words you added: those lists have
  their own filters.
- **Menu bar icon.** Settings → General → Menu bar: keep the capsule, or show
  the layout as plain letters, as the system's own icon, or as a single
  Perekey mark. The icon can show always, only when there is news (a pause,
  automatic switching off, a call being recorded), or never. Open Perekey
  again from Finder or Spotlight and Settings opens, so a hidden icon is
  never a dead end. Settings also tells you when the system's input menu and
  Perekey show the language twice, or when neither shows it. With voice on
  and the icon hidden, you can still record a call and transcribe a file:
  Settings → Voice → Recordings and the Transcripts window have the same
  buttons, and Finder's “Open With” offers Perekey for audio and video files.
- **Hyphen.** Settings → General → Corrections: a Russian word typed without
  its hyphen gets it back: «вопервых» → «во-первых», «чтото» → «что-то»,
  «изза» → «из-за», «помоему» → «по-моему». Rules over the dictionary cover
  whole classes, not just a list: по- with an adverb («поновому»,
  «попрежнему», «поанглийски», «полисьи»), -то, -либо, -нибудь, -таки after
  pronouns and adverbs («вообщето», «наконецто», «опятьтаки»), a word typed
  twice («тихотихо»), -ка after an imperative («давайка», «нука»), and вице-,
  лейб-, унтер-, штаб- («вицемэр»). Only words whose merged spelling is no
  word; a capitalised one inside a sentence is a name and stays. On the
  Tatoeba sentences 85 % of hyphenated words typed merged come back, up from
  78 %. A hyphen typed as a space comes back too
  where the two words cannot be right text: «во первых» → «во-первых», «что
  нибудь» → «что-нибудь», «кое что» → «кое-что»; «что то», «по моему», «кое с
  кем» stay as typed. Off by default; Backspace undoes it and Perekey leaves
  that word alone from then on, in both spellings.

- **Choose what the menu shows.** Settings → General → Menu: switch off the
  blocks you never use (the mode card, the pause, the update, About and the
  rest), pick 0, 3 or 5 rows for recent corrections and dictations, and bring
  back what is hidden by default: «Launch at login», «How to Use Perekey» and
  the layouts as a list in the menu instead of opening them from the header.
  A small copy of the menu next to the list follows each switch and says
  whether it fits this screen or will scroll. In the menu itself, a right
  click (or Control-click) on a block offers «Hide from Menu» and «Customize
  Menu…». The layout header, «Settings…», «Quit», a found update and a
  dictation that was not saved always stay. «Reset to Default» puts it all
  back.

### Changed

- **The menu always fits the screen.** On a small display a long menu no
  longer runs off the bottom: the header stays and the rest scrolls. It is
  also shorter. The layouts open from the header (click it), the same
  correction several times is one row with «×3», the last three dictations
  take one line each, and «Launch at login» and «How to Use Perekey» moved to
  Settings → General.

### Fixed

- **One Backspace no longer stops a word from being fixed for good.** A
  Backspace meant for the space after a fixed word ("jrtq " came out "окей ",
  and you wanted a comma) used to put the word on "Learned" everywhere, and
  Perekey never fixed it again. Now an undo counts only when you go on typing
  with the word as you typed it; Undo in the hint counts more. When a word is
  undone often enough, the hint asks whether to leave it alone only here,
  everywhere, or not at all. If you do not answer, or the hint is off, the word
  is not learned: it waits under «Waiting for your answer» in Settings → Words,
  where you can answer later. Retyping a learned word by hand makes Perekey fix
  it again. Words learned from a single undo go back to being fixed until you
  undo them again.
- **Missing access is no longer silent.** Without Accessibility access, for
  example after a reinstall, the setup window comes to the front, opening
  Perekey again opens its access step, Settings shows a banner, and the menu
  bar item stays on screen with a warning and a «grant access» row. Perekey
  also notices a revoked access within seconds, not at the next app switch,
  and the access step explains what to do when System Settings shows the old
  copy switched on.
- **The first word after switching apps is fixed too.** In Electron apps
  (Slack, Obsidian, Orca and others) a word in the wrong layout typed right
  after you switched to the app often stayed as typed, and only the next word
  was fixed. Perekey now waits for the app to name the field you type in and
  judges that first word as well.
- **A comma after a word in the wrong layout stays a comma.** If you type
  “нет,” with English on and the comma on the English comma key, Perekey now
  gives “нет,” instead of leaving “ytn,” or typing “нетб”, also when it has
  switched the layout before you reached the comma. The same goes for a
  period, a semicolon and a colon. Backspace right after gives “ytn,” back.
- **The hint no longer covers the line you type.** In apps that report the
  cursor a line too high or outside the window, as Telegram does, the hint
  now sits under or above the whole input field, not on the text.
- **The hint no longer stays under a pointer the caret covered.** The hint comes
  up just under the cursor, often where the pointer was left, and it stayed
  until you moved the mouse. Now the pointer holds the hint only after it
  moves, and a finished word ends the hint either way. The hint's glow is no
  longer cut off at the edge.
- **A call recorded in the browser can be transcribed.** «Расшифровать
  файл…» and a drop on the menu bar item now read WebM and Matroska files
  (.webm, .mkv, .mka) with Opus or AAC audio, such as a call recorded in the
  browser or by OBS. A file in a format Perekey cannot decode (Vorbis in WebM,
  WMA, WMV, FLV, AVI) now says which format it is and to convert it to m4a or
  mp3, instead of «the file has no audio».

## [0.2.0] - 2026-10-14

### Added

- **Voice input.** Tap the right Option key, say a phrase, tap again, and the
  text lands at the cursor, in any field. Or hold a shortcut such as ⌥Space
  while you speak. Russian, English and Ukrainian work in one phrase, and
  Perekey can switch the layout to the language you spoke. The right Option key now belongs to
  voice, so retyping moves to the left one; the first launch explains this,
  and you can pick another key to keep Option as it was. Voice needs a Mac with
  Apple Silicon and macOS 15 or newer. On any other Mac Perekey works as
  before, and the Voice tab says why.
- **Speech models on your Mac.** Pick Parakeet (Russian, Ukrainian, English and
  22 more European languages) or Whisper (99 languages, Belarusian included)
  in Settings → Voice, and download it with one button. Nothing is
  downloaded before you click, and recognition runs on this Mac: with a local
  model voice makes no network requests.
- **Clean text without a language model.** Filler words go, and your
  dictionary of names and terms helps the recognizer. Recent dictations stay
  for 7 days, so a lost phrase can be pasted again; turn the history off or shorten it in Settings.
  Audio of dictations is not kept unless you tick “Keep the audio of
  dictations”.
- **Voice modes.** A mode decides what happens to the text after recognition:
  as said, a clean draft, a short message, an email, a terminal mode that adds
  nothing and never presses Enter, or a translation into English. Perekey
  picks the mode by the site, then by the app, and you can write your own.
- **Dictation shows in full in terminals.** In Terminal, iTerm2, Ghostty, Orca
  and other terminals the text is typed, not pasted, so Claude Code and
  similar tools no longer fold a long dictation into “[Pasted text #1]”. Text
  with a line break is still pasted, and typing leaves the pasteboard alone.
  Settings → Apps lets you choose paste or typing for any app.
- **Your own LLM or cloud, only on your terms.** Point a mode at OpenAI, Groq,
  Ollama, LM Studio or any server with an OpenAI-compatible API. The key stays
  in the Keychain, and Perekey asks before the first request to each server.
  Cloud is off until you set it up.
- **Transcripts.** A new window lists your transcripts: drag in an audio or
  video file to turn it into text with timestamps and speakers, search inside
  a transcript, click a phrase to hear it, and export to TXT, Markdown, SRT, VTT
  or JSON. A long recording is split, queued, and finished in the background.
- **Summary and meeting minutes.** A finished transcript can become a summary
  or meeting minutes, made by a language model on this Mac by default. A cloud
  model works only if you pick it and allow sending the transcript, which holds
  other people’s words. The text is saved beside the transcript.
- **Record a call.** Record a call from the menu: your microphone is “Me”, the
  sound of one app or of the whole Mac is “Others”, and each gets its own
  track, so the transcript tells who said what. Perekey asks for “System Audio
  Recording” the first time. A recording survives a crash or a change of
  headphones. After you stop, the call is transcribed and the audio stays on
  this Mac; choose to keep it always, for 30 days, or to delete it after
  transcription. Calls and transcripts stay out of Time Machine unless you
  turn that on.
- **Keep the macOS shortcut.** If you switch layouts with ⌃Space, ⌘Space or
  the 🌐 key, pick “As now in macOS”: Perekey leaves switching to macOS and
  only adds Option to retype the word. Onboarding picks it for you when you
  have changed that shortcut yourself.
- **Your own switch shortcut in onboarding.** Click the keys of “Switch layout”
  and press any shortcut, such as ⌥Space.
- **For organizations.** Configuration profiles can turn voice, cloud
  services, model downloads, call recording, call audio and the Time Machine
  option off, and cap how long the history is kept. See
  `docs/managed-preferences.md`.

### Changed

- **Voice and privacy.** Voice is silent where macOS hides the keys (Secure
  Input) and in password fields. Everything else about privacy is as before:
  typed text is never saved. The network now has two more reasons to wake up,
  both yours: the “Download” button of a speech model, and a mode that you
  pointed at a cloud server or an LLM.
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
- **A bigger download.** Voice adds the speech libraries to the app. The
  speech models themselves are not in the DMG.

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

[Unreleased]: https://github.com/tlgnkl/perekey/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/tlgnkl/perekey/releases/tag/v0.2.0
[0.1.1]: https://github.com/tlgnkl/perekey/releases/tag/v0.1.1
[0.1.0]: https://github.com/tlgnkl/perekey/releases/tag/v0.1.0
