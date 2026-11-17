# TES-316 — inherited terminal colour suppression

## Evidence and triage

A controlled isolated native fixture emits identical saved 16-colour, 256-colour, true-colour and bold/dim bytes into three Ghostty configurations: default reference, cached Workbench dark palette and cached Workbench light palette. All three render distinct hues. The fixture uses GhosttySwift 1.0.10 and reports bundled Ghostty `1.3.2-HEAD-+2a3d93f77`. This does not reproduce general ANSI rendering loss.

A later read-only process inspection identifies seven real Claude/Codex CLI children through their ancestry under the running Workbench application. Only these colour keys are selected: TERM, COLORTERM, NO_COLOR, FORCE_COLOR, CLICOLOR and CLICOLOR_FORCE. No prompts, full command lines, unrelated environment values or credentials are emitted.

The Workbench host has `TERM=dumb`, empty COLORTERM and `NO_COLOR=1`. All seven managed CLI children retain `NO_COLOR=1`, even though the launch builder replaces TERM with `xterm-256color` and COLORTERM with `truecolor`. No known no-colour command flag is present. The saved Workbench preferences contain no custom CLI environment override key.

This proves propagation of the non-interactive host's colour-disable setting into interactive terminals. It supplies a concrete launch-environment defect. A before/after capture of actual provider output remains pending; the code change must not be described as observed provider colour restoration yet.

Frequency 10/10 in the observed host context (seven of seven managed children); severity 3/10; score 30.

## Change

`EmbeddedTerminalLaunchBuilder.makeProcessEnvironment` removes inherited NO_COLOR only when the parent host has absent/empty/dumb TERM and absent/empty COLORTERM. That context describes the observed non-interactive host. A meaningful inherited terminal context keeps its NO_COLOR choice.

Explicit Workbench custom CLI settings still merge last. An explicit NO_COLOR setting, TERM choice or COLORTERM choice therefore remains authoritative. No other inherited colour flag is stripped. Existing terminal processes and saved preferences are not modified.

An injected inherited-environment parameter allows deterministic regression cases without changing the test process's real environment.

## Verification

Implementation agent runs the static motion guard, shell guard and `git diff --check`: all pass. No unit tests or app build run by this agent. Separate tester must run `EmbeddedTerminalLaunchBuilderAgentHubCLITests` and `ClaudeLaunchEnvironmentTests`, then the integrated full gate.

The fixture and its reproduction files remain local at `/private/tmp/tes316-probe/`; detailed diagnostic handoff is `/private/tmp/tes316-colour-diagnosis.md`. Its app is closed. No further native windows may open while the user works.

Actual provider output after the fix, resumed terminals, splits, theme changes, relaunch and the three required native revision cycles remain unverified. These require a future non-disruptive verification path. Existing active sessions must not restart for this check.
