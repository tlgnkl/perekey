---
version: 1
slug: "design-mockup-html"
primary_target: "design/mockup.html"
related_targets: []
---

# Surface: Perekey desktop mockup

Scope: one interactive HTML page that imitates the native macOS app on a live
desktop: menu bar indicator and dropdown, caret hint with undo, onboarding
(3 steps), settings window (General, Corrections, Shortcuts, Apps, Words,
Privacy, About), a chat window for typing, and a mock-only control that
drives the pause reasons. Mode: Operate.

Audience: the founder judging the visual direction; later contributors.
Task: show how Perekey looks and behaves in every touchpoint, in Russian.
Constraints: must read as a native Mac app (macOS 26 Liquid Glass), not a
website. No invented metrics, users or testimonials.

## Direction contract

THESIS: Every correction is a strip of glass laid over a word, like correction
tape. The category default (keyboard icons, flags, toggle grids) is refused:
Perekey's identity is the glass strip that covers, retypes and peels back.

OWN-WORLD: macOS 26 chrome, SF Pro, translucent windows. One accent: indigo
#5E5CE6 and its tints. Glass strips: frosted, 0.5px light rim, soft indigo
under-glow. Strip shapes recur as the menu bar capsule, segmented thumbs,
timing bars, list highlights. Hatched strips mean "ignored time/zone".

STORY: the viewer sees Perekey fix a word, undo a false fix, learns the
shortcuts in onboarding, and finds every setting where a Mac user expects it.

FIRST VIEWPORT: full desktop. Menu bar with the glass RU/EN capsule at right;
onboarding window centered, step 1; chat window behind at left; a dock at the
bottom to switch scenes. The capsule is the primary interaction.

FORM: native macOS desktop imitation with the glass-strip motif; candidate 4
of the grounded list; seed key 5dce3a43.

Signature interaction: the glass strip correction (cover → retype → peel on
Backspace), shared by the chat, onboarding demo field and caret hint.
Motion grammar: strips wipe with clip-path and backdrop blur, springs on
thumbs (cubic-bezier(.2,1.3,.3,1)), nothing else bounces.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
