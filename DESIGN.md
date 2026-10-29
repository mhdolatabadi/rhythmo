---
name: rhythmo
description: A private music locker in dark glass, Persian and right to left.
colors:
  night: "#070810"
  surface: "#121522"
  surface-strong: "#191D2D"
  surface-raised: "#23283A"
  ember: "#FF626A"
  on-ember: "#250005"
  ember-container: "#462026"
  on-ember-container: "#FFDADB"
  violet: "#8D7CFF"
  violet-container: "#2A2454"
  on-violet-container: "#E5DFFF"
  text: "#F5F1F7"
  text-muted: "#D0C8D4"
  outline: "#8B8290"
  outline-quiet: "#3C3743"
  glass-border: "#FFFFFF33"
  glass-border-soft: "#FFFFFF1F"
typography:
  display:
    fontFamily: "Vazirmatn"
    fontSize: "26px"
    fontWeight: 800
    lineHeight: 1.3
  headline:
    fontFamily: "Vazirmatn"
    fontSize: "22px"
    fontWeight: 800
    lineHeight: 1.35
  title:
    fontFamily: "Vazirmatn"
    fontSize: "17px"
    fontWeight: 800
    lineHeight: 1.4
  body:
    fontFamily: "Vazirmatn"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.6
  label:
    fontFamily: "Vazirmatn"
    fontSize: "13px"
    fontWeight: 600
    lineHeight: 1.4
rounded:
  xs: "8px"
  sm: "12px"
  md: "14px"
  lg: "18px"
  xl: "24px"
  sheet: "28px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  xxl: "24px"
  xxxl: "32px"
  huge: "48px"
components:
  button-primary:
    backgroundColor: "{colors.ember}"
    textColor: "{colors.on-ember}"
    rounded: "{rounded.md}"
    padding: "10px 16px"
    height: "48px"
  button-tonal:
    backgroundColor: "{colors.violet-container}"
    textColor: "{colors.on-violet-container}"
    rounded: "{rounded.md}"
    height: "48px"
  icon-button:
    rounded: "{rounded.pill}"
    size: "48px"
  card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.lg}"
  sheet:
    backgroundColor: "{colors.surface-strong}"
    rounded: "{rounded.sheet}"
  track-row:
    height: "56px"
    rounded: "{rounded.md}"
---

# Design System: rhythmo

The source of truth is `lib/core/design/tokens.dart`; this file explains
how to use it. The debug-only gallery (Settings → «سامانهٔ طراحی») shows
every token and component, and `test/design_system_test.dart` keeps the code
honest (see *Do's and Don'ts*).

## Overview

**Creative North Star: "Listening at night"** *(proposed, to be confirmed by
the owner)*

rhythmo is a dark room with music playing. The canvas is near-black
night, lit by a still aurora of two lights: ember red from the top corner
(the music, and anything you can press to make it play) and a cool violet
from the opposite side (secondary, the library's quiet companion). These
are the only two brand colours; a screen is never tinted by the playing
track (a cover without art still gets its own quiet tile colour). Surfaces
are frosted glass: translucent, softly bordered, and blurred only where a
layer truly floats over content. The interface is an
*Operate* surface: scanning a library, finding a song and controlling
playback outrank decoration, and the layout is compact: small covers, tight
rows, bold but modest titles. Its personality lives in precise details: the
still aurora and the small equalizer beside the playing track, the only
thing that moves on its own.

**Key Characteristics:**
- Dark first. The dark glass theme is the brand and the default. A light
  theme (Settings → appearance, from #281) uses Material's scheme seeded
  from a deeper ember (`RhythmoColors.lightSeed`): its containers are plain
  tonal fills, not translucent glass, and its focus ring is that ember.
- One accent at a time. Ember marks the primary action and the playing
  state; violet marks selection and secondary emphasis.
- Glass with restraint. Blur is reserved for chrome and panels; cards and
  rows stay flat.
- Persian first: right to left, Vazirmatn throughout, and generous line
  heights for diacritics.

## Colors

A near-black night with one warm and one cool light.

### Primary
- **Ember** (#FF626A): primary buttons, the playing line in lyrics,
  sliders, focus rings and the active tab. Text on it is **On-ember**
  (#250005). The play control is the exception: it is white (Text on
  night), the brightest thing on the player.
- **Artwork tints** (`artworkTint`): tiles standing in for missing cover
  art take dark hues between violet and ember only, never green or blue.
- **Ember Container** (#462026) with **On-ember Container** (#FFDADB): the
  playing track's artwork tile and other "now" highlights.

### Secondary
- **Violet** (#8D7CFF) and **Violet Container** (#2A2454) with
  **On-violet Container** (#E5DFFF): selected chips, toggles that are on
  (shuffle, repeat), empty-state badges.

### Neutral
- **Night** (#070810): the canvas, from which the ambient gradient
  (#17101D → #090B14 → night) rises. On it sit two blurred glows, ember
  (26%) at the top end corner and violet (20%) on the start side, fading
  into night at the bottom (`RhythmoBackdrop`). The aurora never moves.
- **Surface / Surface Strong / Surface Raised** (#121522, #191D2D,
  #23283A): glass bases, sheets and the highest container.
- **Text** (#F5F1F7) and **Text Muted** (#D0C8D4): both meet 4.5:1 on every
  surface, including every artwork tint.
- **Outline** (#8B8290) for control borders (3:1). **Outline Quiet**
  (#3C3743) for dividers.
- **Glass Border** (white at 20%) and **Glass Border Soft** (white at 12%).

### Named Rules
**The One Light Rule.** A screen has one bright filled control at a time:
the action that matters most. On the now-playing screen and the mini
player that is the white play button; elsewhere it is ember. Everything
else is tonal, outlined or text.

**The No-Grey-On-Colour Rule.** Text on a tint or container uses that
container's own "on" colour, never a generic grey.

## Typography

**Font:** Vazirmatn (bundled, weights 400, 500 and 700; 800 renders as the 700 cut), with Latin and
digits in the same family. Persian digits come from `persianDigits()`.

**Character:** One family carries everything. Hierarchy comes from weight
(800 for headings, 400 for reading) and size steps, never from a second
typeface.

### Hierarchy
- **Display** (800, 26px, 1.3): rare. The library's large collapsing title.
- **Headline** (800, 22px, 1.35; headlineSmall 20px): the now-playing
  title, dialog titles. Titles are bold, not big.
- **Title** (800, 17px, 1.4; titleMedium 700, 14px): section and sheet
  headings, list titles.
- **Body** (400, 15/13px, 1.6): descriptions and lyrics. Lines stay within
  65–75 characters (`RhythmoSpace.readingWidth`).
- **Label** (600, 13px; 500, 11.5px): buttons, chips, times. Times use
  tabular figures.

### Named Rules
**The Diacritic Room Rule.** Persian body text never goes below a 1.5 line
height; Arabic-script marks must not collide.

## Layout

- **Phones** (from 360px): a 16px gutter, and 24px for sheet and section
  headings. Floating chrome (the mini player, FABs) reserves its own space:
  lists end with the bottom system inset (`rhythmoListBottomPadding`) plus
  the chrome's height, so the last row is never covered.
- **Desktop:** content is centred and capped at 960px
  (`RhythmoSpace.pageWidth`). Lists of settings rows are capped at 720px
  (`listWidth`), and reading columns such as now playing and identify at
  520px. Nothing touches the window edges.
- **Spacing rhythm:** 4/8/12/16/20/24/32/48. The app is compact: use tight
  steps (4–8) inside a group and 12–16 between groups, with more space
  above a heading than below it. 24 and up are rare.
- **Density:** list covers are 40px and track rows 56px tall; controls
  stay compact visually but every touch target is still at least 48px.
- **Direction:** RTL by default. Time and transport stay left to right, as
  on every player. Each lyric line takes the direction of its own text.

## Elevation & Depth

Depth is a hybrid of tonal glass and a few soft shadows. Three glass levels
(`RhythmoGlassLevel`):

- **Chrome** (blur 24, shadow): the mini player and anything floating over
  scrolling content.
- **Panel** (blur 18, shadow): grouped panels and result cards.
- **Card** (no blur, no shadow, soft border): cards and rows inside a panel
  or list.

### Shadow Vocabulary
- **Lift** (`0 12px 32px #00000073`): chrome and panels only.
- **Artwork** (`0 16px 32px -12px #00000073`): the now-playing artwork,
  about 80% of the column wide, with an 18px radius. It holds still while
  playing and paused alike.

### Named Rules
**The Blur Budget Rule.** At most two blurred layers are on screen at once,
and list rows are never blurred: blur costs frames on low-end phones.

## Shapes

- **Controls** (buttons, fields, list tiles): 14px.
- **Surfaces** (cards, menus): 18px.
- **Panels and dialogs**: 24px.
- **Sheets**: 28px on the top corners only.
- **Artwork tiles**: about 27% of their size.
- **Pills** (999px): only the tab indicator and small chips.

## Components

All live in `lib/core/design/` and are exported from `design.dart`.

- **Buttons:** the Material 3 buttons, styled by the theme.
  - Filled (one per screen), tonal, outlined, text and icon buttons.
  - Every one is at least 48px and shows a 2px ember ring under keyboard
    focus.
  - Disabled buttons fade but keep their shape.
  - The add button is the single icon-only «+» (from #251); new add actions
    join its menu instead of adding buttons.
- **RhythmoTrackRow:**
  - Layout: artwork tile, title, the artist (or where it plays from), then
    supporting detail such as the file size, then actions.
  - At least 64px tall, with single-line ellipsis in any script.
  - The playing row uses the ember container tile with a waveform.
- **RhythmoSectionHeader:** a title (marked as a heading for screen readers),
  an optional subtitle and an optional trailing action.
- **RhythmoStateView:** the empty, error (`.error`) and loading (`.loading`)
  states.
  - Each has a badge, a title, a message that says what to do next, and at
    most one action.
  - Errors and loading are announced to screen readers.
- **RhythmoSheetFrame + showRhythmoSheet:** every bottom sheet has a heading row
  and a body. Scrollable bodies end with the bottom inset.
- **showRhythmoConfirm:** confirmation dialogs. «انصراف» is the safe default
  and takes keyboard focus; destructive actions are drawn in the error colour.
- **GlassSurface / GlassSurface.level:** the glass layers above.
- **Chips, sliders, tabs, inputs, snackbars, tooltips:** themed in
  `lib/app/app_theme.dart` from the same tokens.

## Do's and Don'ts

- **Do** take every colour, radius, motion duration and spacing value from
  `tokens.dart`. `test/design_system_test.dart` fails on raw colours and
  radii anywhere in `lib/`, and on millisecond animation durations in UI
  code. Files not yet migrated are listed there, and those lists only
  shrink.
- **Do** run every animation through `RhythmoMotion.of(context, …)` so
  reduce-motion turns it off. Use `standard` easing for most changes and
  `emphasized` for arrivals.
- **Do** test new UI at 360px with a 34px gesture inset, and at a desktop
  width.
- **Don't** add a second accent, gradient text, or blur on list rows.
- **Don't** use emoji or Unicode glyphs as icons. Use `RhythmoIcons`
  (Phosphor) only, never Material `Icons.*`.
- **Don't** put grey text on coloured containers (see *The
  No-Grey-On-Colour Rule*).
