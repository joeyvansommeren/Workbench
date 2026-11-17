# TES-267 — Terminal-first session entry

## Scope

Ordinary session entry defaults to Terminal. Result remains an explicit action.
Leaving a session resets only its visible content mode and Result flag. Files,
navigation state, side panels, terminal workspaces, processes and drafts remain
owned by their existing stores. Pending-to-resolved identity changes preserve
the current destination, regardless of notification order.

Explicit content and file requests dismiss Result. The content-mode setter does
this before its unchanged-mode check, so asking for an already-selected Diffs
or Terminal view still reveals that destination.

The terminal-under-Result view hierarchy is unchanged. `SessionDetailView` keeps
its content mounted and conceals it through opacity, hit testing and native
accessibility visibility. This source inspection does not prove both terminal
backends retain focus and scrollback at runtime.

## Verification handoff

Separate tester must run SessionDetailStateModelTests, SessionNavigationModelTests,
SessionResultStateTests and SessionDetailReviewTests, then the full `make test`
gate before PR publication. Check motion/shell lint and whitespace. Report CI
separately. No tests were run by the implementation agent.

## Native iteration gate — incomplete

The existing installed Workbench instance is accessible through CUA at
`/Applications/Workbench.app`. It contains active user work. It was observed,
but not closed, replaced or used as evidence for this patched build.

An isolated app build passed (xcodebuild exit 0) with derived data at
`/private/tmp/workbench-tes267-derived`; build log:
`/private/tmp/workbench-tes267-build-cycle1.log`.

No isolated native fixture/profile exists in the inspected launch paths. Three
actual build → inspect → critique → revise cycles remain required. No cycle is
claimed complete. Native coverage must include both providers/backends,
initial/restored entry, pending resolution, explicit Result/file/diff requests,
approval/input routes, terminal process identity/scrollback/drafts, keyboard and
VoiceOver, narrow windows, both themes and Reduce Motion. Keep TES-267 In Progress
until that gate has real evidence.
