# Workbench pull-request review verification

15 November 2026. Scope: personal Workbench pull requests [16](https://github.com/joeyvansommeren/Workbench/pull/16), [35](https://github.com/joeyvansommeren/Workbench/pull/35), [36](https://github.com/joeyvansommeren/Workbench/pull/36), and [37](https://github.com/joeyvansommeren/Workbench/pull/37).

## Review

The requested Compound Engineering review completed for all four original PR heads. PR 16 has no actionable source finding. PR 35 has two confirmed findings; PR 36 has no actionable source finding; PR 37 has three confirmed findings. The large reviews sampled their scopes. Full plan completeness and live accessibility interaction are not established. Remote PR reviews used an in-process adversarial reviewer; no cross-provider peer is claimed.

Independent GPT-6 Astra reviews of the applied fixes report no remaining actionable findings. Findings returned to their authors. Runtime results below are separate from static review.

## PR 35 fixes

- Save a result and its repository launch recipe in one SQLite transaction. Update the displayed recipe and result only after persistence succeeds. A real failing SQLite trigger verifies rollback, followed by a successful save.
- Probe GET-only destinations when HEAD returns 405 or 501. Preserve route/query, remove only the fragment, and reject a changed final response URL. Each probe owns its session, cancels on delivered response headers and respects caller cancellation. Its total resource deadline is at most four seconds, in addition to the request idle timeout.
- Inject an inert accessory-session detector by default in terminal unit tests. The relationship test retains its explicit detector. Tests no longer scan the real session directories through that fixture.

Darwin may buffer sparse plain text for MIME detection until 512 bytes or EOF. Real loopback tests verify open SSE and 512-byte plain-text responses without EOF, cancellation/disconnect, and a sparse trickle stopped by the resource deadline. A sparse one-byte plain-text response can still be reported unreachable at the deadline. No zero-body-byte guarantee or real redirect-chain test is claimed.

## Local checks

- PR 35 plus the merged crash fix: all six fast packages and motion/shell guards pass. Full Core run: **2319 total, 2270 passed, 33 failed, 16 skipped**.
- Main plus the crash fix, before the feature changes: **2217 total, 2164 passed, 37 failed, 16 skipped**. Twenty-six failed test IDs also fail in the PR 35 run.
- Focused PR 35 run: **66 tests in eight suites, all passed; zero failures or skips**. This includes all seven failure cases not shared with that baseline, plus health, transaction, result model, and terminal tests. Passing in a bounded run does not establish every broad-run failure as pre-existing.
- The configured dependency linters report zero violations in 92 and 157 files. Xcode also reports two plugin command errors because an `Output` folder is absent, while returning a successful focused test result. This is not described as an entirely clean plugin gate.
- Changed Swift lines pass formatter checks; unchanged formatter warnings remain. Parser and whitespace checks pass. No hooks or test quarantines are bypassed.

## Session-row verification

The three PR 37 fixes have independent static review and a local affected run: **111 total, 107 passed, zero failed, four existing quarantined skips**, across fourteen suites. They coalesce a trailing diff refresh, retry a captured visible read cursor, and retain the recorded-result action when a linked PR is ineligible. The scan test does not explicitly gate invalidator entry before the first evaluation finishes. Retries stop after five attempts; persistent database failure needs a later visibility/activity event.

## Review/launch and final app verification

The fresh PR 36 launch/review/diff batch reports **197 total, 194 passed, zero failed, three existing quarantined skips**, across nineteen suites. It runs on the integrated feature checkout. The native restored-selection regression passes.

The complete Debug macOS application builds successfully at `a234864a154a008f1f906dbb1579031a540f389e`. That integration contains the three merged predecessor PRs, the session-row feature, and all five retained review fixes. The integration's only source difference from the focused-test checkout is the already-reviewed workspace-switch crash fix; its metadata store is byte-for-byte unchanged. Subsequent edits for this verification record change documentation only.

Both dependency linters report zero violations in the app build. Creating their declared generated `Output` directories resolves the earlier plugin output-directory error for this build; no linter, hook or quarantine is disabled and no dependency source is patched.

Core tests use the module's prescribed lockfile; the complete app uses the app workspace's lockfile. They have four different common dependency revisions (TextStory, Swift Collections, Rearrange and Swift Async Algorithms). No lockfiles are changed here. A compile pass does not establish runtime equivalence across those versions.

Direct keyboard activation, VoiceOver, RTL and large-text interaction remain unverified. The installed app is untouched. No all-green Core or CI result is claimed. Separate drawer and commit-tree work is outside this review and remains in its own worktrees.
