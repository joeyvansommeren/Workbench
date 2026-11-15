# Launch settings and review clarity: delivery verification

Date: 15 November 2026. Base: `ee3fc3f27f6c111002c333c5c34892649286abf8`, the head of pull request #35. This change uses `codex/workbench-first-ten` as its pull request base.

## Delivered scope

- Claude agent progress summaries default off for Workbench-launched Claude processes. A native setting enables them. Embedded new/resumed/accessory launches, external Terminal commands, background tasks and long-lived programmatic clients read the preference at launch. The app does not change global shell or Claude configuration. Claude settings can override inherited environment values; the setting explains this limit.
- The compact diff has a visible Expand diff action and separate bounded file/code scrolling. Mode, selected file and the existing expansion destination remain connected. A restored offscreen selected file scrolls into view after the list appears.
- The session header shows Context N% with estimate details. Provider, repository and branch identity remain available.
- Reviews distinguishes Review changes on GitHub from Ask agent to review. Open is neutral. Equivalent decorated Project status tags retain their exact source detail. Full titles wrap, optional column choices persist as UI preferences, and narrow layouts hide columns without changing those choices. Project empty/recovery text remains separate from actual pull request absence; failed refreshes retain saved rows.

Related to TES-277, TES-285, TES-286 and TES-287.

## Local verification

- Final affected native batch: **257 total, 254 passed, zero failed, three existing quarantined skips**, across 19 selected suites. The skipped tests are not counted as passing.
- All six fast Swift packages pass: AgentHubVoice, AgentWorkflowCore, AgentHubCLI, AgentHubGitHub, SimulatorPreview and Storybook. Motion and shell guards pass.
- Final complete Debug macOS application build succeeds. Nothing is installed or replaced.
- Configured dependency SwiftLint reports zero violations in its 92-file and 157-file runs. Source parsing and changed-file whitespace checks pass. The repository has no separate app-wide lint target.
- Process tests use harmless child executables to capture actual launch values and verify late preference reads. No real Claude invocation is needed for those tests.
- Native Reviews tests generate 18 synthetic-data images at content widths 1144, 743, 604 and 203 points, in light/dark and default/restored column states, plus detail views. The images and native scroll geometry show wrapping titles and aligned columns in these cases. An isolated light-mode capture initially omitted the app's background; the test now renders that same existing surface.
- The restored-selection regression fails without the restoration task (one test, 2.136 seconds) and passes with it (one test, 0.163 seconds). The test waits asynchronously so SwiftUI tasks can run; its viewport assertion and two-second deadline remain unchanged. Temporary diagnostic output is removed. The final wider batch includes this regression.

## Independent review

Three bounded specifications were independently verified before implementation. Five simplification reviews returned one accepted shared launch-policy cleanup. Six independent code-review lenses completed, followed by native UI stress review and a fresh review of the restored-selection fix. Supported changes returned to their original authors.

The completed full review receipt is `20261115-next-four-8350bfeb` (`status: complete`). Its verdict is **Not ready** because the full local gate and runtime checks below remain unresolved. The separate cached-selection fix review has no actionable findings and confirms the frozen source/test hashes and RED/GREEN evidence. That does not clear the full-gate limitation.

## Limits before merge

The earlier full `make test` run fails: Core reports **2335 total, 2279 passed, 40 failed and 16 skipped**, including timing, timeout, session-restoration and headless UI failures. Xcode restarts test processes during that run. The causes are not all established as pre-existing. The accessory relationship case that fails there passes in the final affected batch. No claim of an all-green full suite or a repair of all 40 failures is made. The last bounded UI fix is verified by the final affected batch and full app build; the full Core gate is not rerun after that fix.

Direct keyboard activation, arrow-key focus routing, VoiceOver, 200% scaling, RTL and empty/error screenshots remain unverified. Production action methods and native images do not prove those interactions. The context header has no dedicated native interaction test. UI stress evidence is synthetic, not user research.

No CI success is assumed. The change is published for review as a draft; it is not ready to merge. The first-ten pull request remains separate and unmerged. No installation, merge, Actions enablement or Linear state mutation occurs.

Task-owned generated builds are removed after publication. Completed managed worktrees are archived through Codex when allowed; primary-worktree protection is respected. Test records and synthetic images remain outside the repository for local review.
