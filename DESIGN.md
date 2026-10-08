---
name: Perekey
description: A macOS menu bar app that fixes words typed in the wrong layout, drawn as strips of frosted glass laid over the word.
colors:
  accent: "#5E5CE6"
  accent-dark: "#7D7AFF"
  accent-fill: "#5E5CE6"
  accent-ink: "#4644D0"
  accent-ink-dark: "#A9A7FF"
  warn: "#C26A00"
  warn-dark: "#FFB340"
  ok: "#1F9D47"
  ok-dark: "#32D74B"
  ink: "#1D1D1F"
  ink-dark: "#F5F5F7"
  ink-2: "#66666C"
  ink-2-dark: "#A1A1AA"
  ink-3: "#A1A1A8"
  ink-3-dark: "#6C6C74"
  window-solid: "#FFFFFF"
  window-solid-dark: "#26262C"
  bubble: "#E9E9EE"
  bubble-dark: "#3A3A42"
  rule: "rgba(0,0,0,0.08)"
  rule-dark: "rgba(255,255,255,0.09)"
  fill: "rgba(0,0,0,0.045)"
  fill-dark: "rgba(255,255,255,0.06)"
  fill-2: "rgba(0,0,0,0.08)"
  fill-2-dark: "rgba(255,255,255,0.10)"
  accent-soft: "rgba(94,92,230,0.13)"
  accent-soft-dark: "rgba(125,122,255,0.18)"
  accent-glow: "rgba(94,92,230,0.45)"
  accent-glow-dark: "rgba(125,122,255,0.50)"
  window-glass: "rgba(251,251,253,0.80)"
  window-glass-dark: "rgba(32,32,38,0.80)"
typography:
  large-title:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "26pt"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  title:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "22pt"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.015em"
  headline:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "15pt"
    fontWeight: 700
    lineHeight: 1.4
  body:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 400
    lineHeight: 1.4
  callout:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "14pt"
    fontWeight: 400
    lineHeight: 1.4
  caption:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "12pt"
    fontWeight: 400
    lineHeight: 1.4
  capsule-label:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "11.5pt"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "0.06em"
  hero-word:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "60pt"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "-0.035em"
rounded:
  keycap-sm: "5px"
  popup: "7px"
  field: "8px"
  segment: "10px"
  row: "14px"
  menu: "18px"
  window: "20px"
  capsule: "11px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "14px"
  xl: "18px"
  pane: "26px"
components:
  capsule:
    backgroundColor: "{colors.accent-soft}"
    textColor: "{colors.accent-ink}"
    typography: "{typography.capsule-label}"
    rounded: "{rounded.capsule}"
    height: "22px"
    padding: "0 11px"
  button-primary:
    backgroundColor: "{colors.accent-fill}"
    textColor: "#FFFFFF"
    rounded: "{rounded.pill}"
    height: "30px"
    padding: "0 16px"
  button-secondary:
    backgroundColor: "{colors.fill-2}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    height: "30px"
    padding: "0 16px"
  switch:
    backgroundColor: "{colors.accent-fill}"
    rounded: "{rounded.capsule}"
    width: "38px"
    height: "22px"
  segmented:
    backgroundColor: "{colors.fill}"
    textColor: "{colors.ink-2}"
    rounded: "{rounded.segment}"
    padding: "2px"
  settings-row:
    backgroundColor: "{colors.fill}"
    textColor: "{colors.ink}"
    rounded: "{rounded.row}"
    padding: "11px 14px"
  keycap:
    backgroundColor: "{colors.window-solid}"
    textColor: "{colors.ink}"
    rounded: "{rounded.popup}"
    height: "24px"
    padding: "0 7px"
---

# Design System: Perekey

## Overview

**Creative North Star: "Стеклянная правка" (the glass correction)**

Every correction is a strip of frosted glass laid over a word, like correction tape: it wipes on, rests while the word is retyped, and peels off on Backspace. The interface is a native macOS 26 window system (translucent windows, SF Pro, system-style controls) in which that one object recurs everywhere a thing is "chosen, fixed or measured". The category defaults (keyboard icons, flags, toggle grids) are not used; the strip is the identity.

The system is quiet. Windows are large, soft glass planes over a colored wallpaper; content sits in inset grouped rows. One indigo accent carries every active, selected and corrected state, so a viewer can find "what changed" by looking for indigo glass.

**Key Characteristics:**
- Frosted strip surface (gradient + 0.5px light rim + indigo under-glow) as the single signature material.
- One accent: indigo, with a lighter dark-mode value and a solid fill kept for white-on-accent.
- Native structure: traffic lights, menu bar, grouped rows, sidebar selection, popovers, dock.
- Hatched diagonal fill means "time or zone that is not counted".
- Springs only on switches, segment thumbs and the menu bar capsule; everything else eases out.
- Light and dark are both first-class and follow the system by default.

## Colors

One indigo accent on cool neutrals, with amber for warnings and green for confirmed permission. Values below are light / dark pairs; SwiftUI should map each pair to one adaptive color.

### Primary
- **Correction Indigo** (#5E5CE6 light, #7D7AFF dark): glyph and line accent: caret, focus ring, selected-preset outline, progress, tinted underline of a fixed word.
- **Solid Indigo Fill** (#5E5CE6 in both modes): the only fill that carries white text: primary button, "me" bubble, switch on-state, send button, key pressed, menu item hover. Does not lighten in dark mode.
- **Indigo Ink** (#4644D0 light, #A9A7FF dark): accent-colored text on glass or tinted fill (capsule label, "Отменить" action, result text, tags).
- **Indigo Mist** (rgba 94,92,230 at .13 light; 125,122,255 at .18 dark): focus halo (3px), tag and action backgrounds, shimmer.
- **Indigo Glow** (rgba 94,92,230 at .45 light; 125,122,255 at .50 dark): the soft under-glow beneath strips and thumbs.

### Secondary
- **Caution Amber** (#C26A00 light, #FFB340 dark; soft tint rgba(255,159,10,.16/.18)): shortcut conflicts, "not granted" pill, late-press timing, the "never sent" strike-through.
- **Granted Green** (#1F9D47 light, #32D74B dark; 16% tint): permission-granted pill only.

### Neutral
- **Ink** (#1D1D1F / #F5F5F7): primary text.
- **Secondary Ink** (#66666C / #A1A1AA): descriptions, sublabels, inactive segment labels.
- **Quiet Ink** (#A1A1A8 / #6C6C74): placeholders, struck-out "from" text, timestamps. Decorative or secondary only; never the sole carrier of essential information.
- **Hairline** (rgba black .08 / white .09): 0.5px inset rim on grouped surfaces, 1px row dividers.
- **Wash** (rgba black .045 / white .06) and **Wash Deep** (.08 / .10): control tracks, inactive switches, hover on icon buttons.
- **Solid Plate** (#FFFFFF / #26262C): keycaps, text inputs, popup buttons, demo field.
- **Window Glass** (rgba 251,251,253 at .80 / 32,32,38 at .80): window body over the wallpaper.
- **Received Bubble** (#E9E9EE / #3A3A42).
- **Wallpaper**: four soft radial blooms (periwinkle, rose, mint, lilac) over #DAD6F3 light; deep navy, plum, teal, violet over #14132A dark. Exists so the glass has color to refract; not a UI color.

### Named Rules
**The One Voice Rule.** Indigo is the only accent hue. Warning amber and permission green are status colors, never decoration. Per-section sidebar icon tiles use macOS-style multi-hue gradients as a native System Settings idiom and do not extend to any other element.

**The White-on-Fill Rule.** White text sits only on Solid Indigo Fill (#5E5CE6). Text on translucent indigo or glass uses Indigo Ink.

## Typography

**Font:** SF Pro (Text below 20pt, Display at 20pt and above); web mock stack is `-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui`. In SwiftUI use the system font; do not name a family. Sizes in the mock are CSS px at 1:1 with macOS pt.

**Character:** Native and unadorned. Hierarchy comes from weight and size steps, not from a second typeface. Digits use tabular figures (clock, timings).

### Hierarchy
- **Hero word** (700, 60pt, 1.0, -0.035em; 34pt on narrow): the onboarding demo word only.
- **Large title** (700, 26pt, 1.15, -0.02em): onboarding step titles.
- **Title** (700, 22pt, -0.015em): settings pane titles; demo field text is 22pt regular.
- **Headline** (700 15pt; 600 13pt for group titles and window title): menu header language name; group headings.
- **Callout** (400, 14pt): chat messages, onboarding lead (14.5pt in the compose field).
- **Body** (400, 13pt, 1.4): rows, menu items, controls. Selected segment and current sidebar item go to 600.
- **Caption** (400, 12pt; 11pt for axis scale labels): descriptions under row titles, menu section labels (600), tags (600 11pt).
- **Capsule label** (800, 11.5pt, +0.06em; 700 17pt, +0.04em in the menu header): the layout code in the menu bar capsule, upper-case by content (EN, RU).

### Named Rules
**The No-Second-Face Rule.** One family. Emphasis is weight (400/600/700/800), never a different typeface.

## Layout

A full-screen desktop: 28pt menu bar on top, windows floating on the wallpaper, a centered dock at the bottom (10pt from the edge). Windows are fixed-size panes, draggable, with 14-16pt title bars: chat 430x470, onboarding 640x580, settings 840x680 (max viewport height minus 150).

Settings is a two-column layout: a 216pt inset glass sidebar (8pt margin, 8pt padding, 32pt rows, 9pt row radius) and a scrolling pane (20 / 26 / 40 / 18pt padding) with a 28pt bottom fade mask. Content is grouped into inset cards; rows are at least 44pt tall with 11pt / 14pt padding, label left (flex), control right, 12pt gap, 1px hairline between rows. Cards are separated by 16pt. Prose is capped (52 to 60ch). Onboarding steps pad 44pt sides and slide 40pt horizontally with blur between steps.

Spacing rhythm in use: 4, 6, 8, 10, 12, 14, 18pt. Below 760px the windows become full-bleed sheets and the sidebar becomes a horizontal chip row (the mock's concession; the real app does not collapse).

## Elevation & Depth

Depth is glass, not paper: translucency plus backdrop blur plus a 0.5px light inner rim, with a tinted soft shadow. The material tiers map to macOS materials: menu bar and dock to `.bar`/`.ultraThinMaterial` (blur 30, saturate 1.8); windows to `.regularMaterial` (blur 50, saturate 1.9); popovers and hints to `.thickMaterial` (blur 40 / 20, saturate 1.9 / 1.8); the strip itself blur 8 (4 over a word).

### Shadow Vocabulary
- **Strip rim** (`inset 0 0 0 .5px rgba(255,255,255,.95), inset 0 -1px 1px rgba(94,92,230,.10)`; dark `.22` white, `.2` black): the light edge on every strip.
- **Strip glow** (`0 6px 16px -6px var(--accent-glow)`): soft indigo light beneath strips, thumbs, selected presets.
- **Window** (`0 30px 80px -20px rgba(20,20,60,.42), 0 3px 10px rgba(20,20,60,.12)` plus .5px rim): large floating windows.
- **Popover** (`0 24px 60px -18px rgba(30,25,90,.45), 0 2px 6px rgba(0,0,0,.08)` plus rim): menu, caret hint, dock tooltips.
- **Keycap edge** (`0 1.5px 0 Wash Deep`, 2.5px on the big key): the physical lower edge of a keycap. Keycap-only; it is not a general offset shadow.

### Named Rules
**The Rim-and-Glow Rule.** Every raised glass surface carries both the light rim and a tinted (never black-only) under-glow. Grey drop shadows alone are wrong.

## Shapes

Generous continuous-curve corners that nest: window 20, menu 18, grouped card 14, inner row 10, segment 10 with 8 thumb inside 2 padding, popup 7, keycap 5 to 10. Buttons, chips, capsule and text pills are fully rounded (radius = half height). Chat bubbles 18, compose field 19. The glass strip clips with `clip-path: inset(... round r)` so it wipes on left-to-right and peels off the same direction. Borders are never solid lines: separation is the 0.5px inset rim or 1px hairline dividers.

## Components

### Menu bar capsule (signature)
A 22pt-tall, 46pt-min glass strip with the layout code in Indigo Ink, 1px indigo ring (35%), rim and 3pt-radius glow. On press it scales to .94 with a spring (`cubic-bezier(.2,1.3,.3,1)`, .3s). On a layout change the label slides up out and the new one in from below (.55s `cubic-bezier(.2,1,.3,1)`) and a white sheen crosses (.85s). Paused: 55% opacity. Off: label struck through. Open: 3pt Indigo Mist halo. A beacon ring (14pt, 1.6s, 3x) draws attention once.

### Glass strip correction (signature interaction)
Cover (clip-path wipe in), retype (old word blurs out, new blurs in under the strip), peel (wipe out). 0.95s `cubic-bezier(.3,.7,.2,1)` in text fields, 6s loop in the onboarding hero. Fixed words keep a 1.5pt indigo 50% underline (4pt offset). An undone fix swaps the glow for a rose one. Shared by chat, the demo field and the caret hint.

### Caret hint
Floating popover (radius 13) with the struck-out original, the new word and an "Отменить" action chip (Indigo Mist, Indigo Ink, 600, radius 8). Enters with `translateY(4) scale(.96)` to rest over .55s `cubic-bezier(.16,1,.3,1)`; exits .2s ease. Non-interactive until shown.

### Buttons
Pill, 30pt (small 24pt). Primary: Solid Indigo Fill, white 500 text, glow and a .5px white top highlight. Secondary: Wash Deep with Ink. Disabled primary falls back to Wash Deep with Secondary Ink. Press scales .97 in .15s.

### Switch
38x22, Wash Deep off, Solid Indigo Fill on, white 18pt knob with a spring (`.4s cubic-bezier(.2,1.3,.3,1)`) over 16pt travel.

### Segmented control
Wash track with rim, 2pt padding, radius 10. The thumb is a strip (thumb gradient, rim, glow) that springs between segments (`.5s cubic-bezier(.2,1.25,.3,1)`), animating transform and width. Selected label 600 Ink; others Secondary Ink. Mini variant: 12pt labels.

### Sidebar navigation
Glass inset panel. One selection strip (32pt) slides behind the current item (`.5s cubic-bezier(.16,1,.3,1)`), current label 600. Each item has a 22pt rounded-square icon tile with a white glyph.

### Settings group and row
Card radius 14 on a faint white row fill with rim; row 44pt min with title, optional 12pt description and a trailing control. Contents of a pane cross-fade and rise 8pt (.25s ease, .45s out).

### Menu popover
318pt wide, radius 18, popover material. Header: 40pt strip with layout code plus language and a hint line; a card with the auto-switch and mode rows; "Последние правки" list where the latest fix is itself a strip and reverted fixes strike through "to"; a command list whose hover is Solid Indigo Fill with white text and shortcut hints (Quiet Ink, 80% white on hover). Enters with scale .92 from top right (.45s `cubic-bezier(.16,1,.3,1)`).

### Keycap and shortcut recorder
Solid Plate keys, radius 7, 600 12.5pt, keycap edge; the big demonstration key (44x40) presses 2pt down and fills Solid Indigo Fill. The recorder is a 28pt plate; recording shows a 1.5pt indigo ring and an Indigo Mist shimmer sweep.

### Timing bar
30pt track on Wash. Counted zone is Indigo Mist (left 76.9%); the not-counted zone is a 135deg hatch of Wash Deep (4pt on, 5pt off). The live bar is a strip; ok = indigo gradient, late = amber hatch with a 1pt amber ring. The hatch is reserved for "not counted".

### Chips, tags, status pills
Chip 28pt pill on Wash; selected becomes the thumb strip with 600 text. Tag is 11pt 600 Indigo Ink on Indigo Mist, radius 6. Status pills 24pt: waiting (Wash with shimmer), denied (amber), granted (green).

### Input
30pt, radius 8, Solid Plate with rim; focus adds the 3pt Indigo Mist halo. Global keyboard focus uses a 3pt accent outline at 55% with 2pt offset.

### Dock
Floating glass bar, radius 24, 54pt icons that lift 6pt and scale 1.08 on hover (.35s `cubic-bezier(.16,1,.3,1)`), tooltips as popovers.

## Do's and Don'ts

### Do:
- **Do** express any new "selected / corrected / measured" state as a glass strip (gradient, .5px rim, indigo glow) before inventing another highlight.
- **Do** use Solid Indigo Fill (#5E5CE6) for anything carrying white text, in both appearances; use Indigo Ink for text on glass.
- **Do** ship every surface in light and dark with the paired values above, and follow the system appearance by default.
- **Do** reserve springs (`cubic-bezier(.2,1.3,.3,1)` family) for switches, segment thumbs and the capsule; use ease-out (`cubic-bezier(.16,1,.3,1)` or `(.2,1,.3,1)`) for everything else.
- **Do** use the hatch (135deg stripes) only for time or zones that are not counted.
- **Do** honor reduced motion: collapse all durations to near zero.

### Don't:
- **Don't** add a second accent hue, or use amber/green as decoration.
- **Don't** use keyboard icons, flags or toggle grids as the brand device.
- **Don't** put black-only drop shadows on glass or rely on solid 1px borders for grouping.
- **Don't** bounce anything outside the three spring components (content panes, popovers, hints, dock do not overshoot).
- **Don't** set essential information in Quiet Ink (#A1A1A8); it is for placeholders and struck-out originals.
