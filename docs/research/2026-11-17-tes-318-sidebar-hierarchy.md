# TES-318 implementation handoff

## Scope and current state

The original nine-file worktree patch was preserved in `/private/tmp/tes318-original-all.patch` and `/private/tmp/tes318-original-staged.patch`, checkpointed, then integrated with current origin/main (`16d19e5f`) without conflicts.

Repository, branch and session rows use one shared inset contract: 10, 18 and 26 points. Guide lines and load-more controls use the session inset. Dark-mode repository text uses medium weight and semantic secondary text; increased contrast retains primary text. Controls and attention counts remain unchanged.

The pre-existing patch contained an unmounted native accessibility outline. The live `SessionTreeList` now mounts it over the scroll viewport and registers row-sized AppKit anchors. Visual rows are hidden from accessibility to prevent duplicate controls. Native outline rows expose hierarchy, selection, collapse, press, current approval detail, and shared context-menu commands. Pointer hit testing remains with SwiftUI. VoiceOver focus requests scroll to the requested row.

The shared menu factories retain the visible menus and accessible actions in one source. Result callbacks are weakly registered by visible rows. Removed rows release captured actions and labels. Offscreen or stale native commands fail closed.

## Validation performed

- Source inspection only.
- `git diff --check` passes.
- No build, lint, unit test or native iteration claims. The parent assigned testing to a separate agent and reserves the Core build slot.

## Separate verification required

Run `SidebarTreeRowsTests`, `SessionRowNativeLayoutTests`, `SessionSidebarPresentationTests`, and `ApprovalResponderTests`; run motion/shell guards, then `make test` before opening a PR. The new viewport test uses a non-frontmost borderless native window and checks visible press/hit testing, plus rejection after scrolling its anchor outside the viewport.

Review the live outline mounting and shared menus independently, including stale menu targets, offscreen focus, collapse and row identity. Inspect changes together with TES-317 before merging overlapping sidebar files.

Three actual build → inspect → critique → revise cycles remain unperformed. Use a safe isolated native app profile; preserve the running user's sessions. Required fixtures: long repo/branch/session names; 3–5 active tasks; collapsed repos; mixed providers; 12-session stress; narrow sidebar; light/dark; increased contrast; inactive window; keyboard order/collapse/context menus; VoiceOver commands and focus; Reduce Motion. No screenshots or source tests substitute for native interaction acceptance.
