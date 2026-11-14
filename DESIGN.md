---
name: Workbench
description: A quiet operations desk for local AI coding workflows on macOS.
colors:
  # Standard palette, light. Dark and Warm values live in WorkbenchPalette.swift.
  surface-window: "#F3F3F4"
  surface-content: "#FFFFFF"
  text-primary: "#1D1D1F"
  text-secondary: "#5C5C62"
  accent: "#0A6CDC"
  status-working: "#0A6CDC"
  status-ready: "#23A047"
  status-attention: "#F08A00"
typography:
  title2: { fontFamily: "Inter Display", fontSize: "17px", fontWeight: 600, lineHeight: "22px", letterSpacing: "-0.008em" }
  title3: { fontFamily: "Inter Display", fontSize: "15px", fontWeight: 600, lineHeight: "20px", letterSpacing: "-0.008em" }
  headline: { fontFamily: "Inter Display", fontSize: "13px", fontWeight: 600, lineHeight: "18px", letterSpacing: "0.01em" }
  body: { fontFamily: "Inter Display", fontSize: "13px", fontWeight: 400, lineHeight: "18px", letterSpacing: "0.01em" }
  callout: { fontFamily: "Inter Display", fontSize: "12px", fontWeight: 400, lineHeight: "16px", letterSpacing: "0.01em" }
  subheadline: { fontFamily: "Inter Display", fontSize: "11px", fontWeight: 400, lineHeight: "14px", letterSpacing: "0.025em" }
  code: { fontFamily: "Geist Mono", fontSize: "12px", fontWeight: 400, lineHeight: "18px", letterSpacing: "0" }
rounded:
  segment: "6px"
  item: "8px"
  row: "10px"
  container: "14px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
---

# Design System: Workbench

## 1. Overview

**North star: "The Operations Desk".** A quiet, precise macOS workspace for long agent sessions.
Compact enough to scan, stable enough to trust. Terminals, diffs, reviews and approvals are the
work surfaces; the chrome stays out of the way.

The new interface (the shell, `Shell/`) is the default. The legacy UI stays behind
`com.agenthub.features.appleShell = NO` until P11b deletes it. These rules apply to the new interface.

- Native macOS behaviour, keyboard first, VoiceOver labels on every control.
- Never show state with colour alone: every status has a glyph shape and a word.
- No decorative gradients, glow, glassmorphism or animated avatars.

## 2. Tokens

Use tokens, never literals. They live in `app/modules/AgentHubCore/Sources/AgentHub/Design/Tokens/`
and match the prototype's CSS one to one (`Fixtures/workbench-apple-tokens.css` guards parity).

| File | Holds |
|---|---|
| `WorkbenchPalette.swift` | Every colour, four palettes (below) |
| `Color+WorkbenchTokens.swift` | `Color.wb*` / `NSColor.wb*`: surfaces, text, borders, accent, status fill/text/tint |
| `DesignTokens+Layout.swift` | Spacing, radius, inset, size, width, motion, shadow (`wbElevation`) |
| `WorkbenchTypography.swift` | Text styles (`wbText(.body)`) |
| `AppearancePreference.swift`, `WorkbenchAppearanceController.swift` | Appearance and palette, applied live |
| `TerminalPalette.swift`, `TerminalPaletteResolver.swift` | Terminal colours |

- **Radius:** container 14 (panel, sheet, popover, palette), row 10, item 8 (button, field, menu item), segment 6, small 5.
- **Sizes:** title bar 52, control 28, row 30, tab 32. **Widths:** sidebar 288, side panel 400, sheet 560, palette 640.
- **Window minimum:** 900. Child minimums must add up to no more than that.

## 3. Palettes and appearance

- **Palette:** Standard (neutral grey, blue accent) or Warm (warm paper, ink accent). Default Standard.
- **Appearance:** System, Light or Dark. Each palette has a light and a dark set.
- The user switches both live in Settings › Appearance; the palette's "Switch appearance" flips light and dark.
- The window root applies `.wbRedrawsOnPaletteChange()`, or views stay stale after a switch.
- WCAG ≥ 4.5 for primary, secondary and tertiary text on content and sidebar, and for each status text on its tint (`WorkbenchPaletteTests`).

## 4. Typography

- **UI:** Inter Display. **Code, paths, branches, terminal:** Geist Mono.
- Styles: `title2` 17, `title3` 15, `headline` 13 semibold, `body` 13, `bodyEmphasis` 13 medium, `callout` 12, `subheadline` 11, `code` 12, `codeSmall` 11.
- Tracking is part of the style: titles −0.008 em, body +0.01 em, small +0.025 em, mono 0. Apply with `wbText(_:)`.
- Mono is for values made by or for tools. Human text stays in Inter Display.

## 5. Components

Reuse `Design/Components/` before you write a new view. `ComponentGallery` (debug) shows each one in every state.

- **Buttons:** `WBPrimaryButtonStyle`, `WBSecondaryButtonStyle`, `WBPlainButtonStyle`, `WBDestructiveButtonStyle`, `SplitButton`, `IconButton`.
- **Controls:** `WorkbenchField`, `WorkbenchSegmentedControl`, `Checkbox`, `FilterChip`, `MenuSurface`, `KeyCaps`.
- **Content:** `StatusChip`, `CountBadge`, `Avatar`, `LetterTile`, `PullRequestGlyph`, `PropertyCard`, `CommandBlock`, `DotMeter`, `EmptyState`, `ErrorBanner`.
- **Elevation:** flat at rest. Shadows (`wbElevation`) only for the content panel, raised controls and floating overlays.

## 6. Status glyphs

`StatusGlyph` draws the shape; `SessionStatusPresentation` maps `SessionStatus` to shape, colour and word.

| Status | Shape | Colour | Word |
|---|---|---|---|
| Thinking, starting | Breathing dot | Working (blue) | Thinking / Starting |
| Running a tool | Spinning arc | Working | Running ‹tool› |
| Waiting for the user | Filled check | Ready (green) | Your turn |
| Approval or input | Filled "!" | Attention (orange) | Needs approval / Needs input |
| Idle | Empty ring | Idle (grey) | Idle |

The glyph animates through `TimelineView`, inside a fixed frame. Never drive it from `@State` animation.

## 7. Terminal

The terminal follows the theme: light in light mode, dark in dark mode, on `surfaceTerminal` (the
content colour). `TerminalPaletteResolver` sets the SwiftTerm colours (background, cursor, selection,
the 16 ANSI colours) and the Ghostty overlay from the palette, and repaints open terminals on a switch. YAML theme
terminal colours apply only to the legacy UI.

## 8. Motion

- **Hover and press change colour only**, on the first frame. No scale on hover or press, anywhere. Press = hover fill + `wbSurfacePressed`.
- **Springs are critically damped** (no bounce): `DesignTokens.Motion.fast` (~120 ms), `.medium` (~240 ms), `.standard` (0.3 s).
- **Always animate through `.wbAnimation(_:)`.** It returns nil under Reduce Motion.
- **Instant:** selection, hover, destination change, ⌘1–4, counts, field focus.
- **Animated:** approval banner, palette fade, repo chevron, "Load more", sidebar toggle. Trailing panels take their width at once; only the contents fade in (`wbPanelEntrance()`).
- **Theme switch:** one window crossfade (`Design/Motion/ThemeCrossfade.swift`).
- `scripts/check-motion.sh` (run by `scripts/test.sh` and CI) fails on hover/press scale and bouncy springs in new-shell code.

## 9. Do's and don'ts

- **Do** use tokens, `wbText` and the components above.
- **Do** pair every status colour with a glyph shape and a word.
- **Do** test each screen in Standard and Warm, light and dark.
- **Don't** hard-code colours, fonts or a dark-only surface.
- **Don't** scale on hover or press, or use a bouncy spring.
- **Don't** use a coloured side stripe thicker than 1 px for selection.
- **Don't** nest cards when a row, divider or tonal surface shows the same hierarchy.
