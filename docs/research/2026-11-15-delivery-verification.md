# First ten Workbench items: delivery verification

Scope: TES-267 through TES-276, implemented in four workstreams from base `96aaeed1b5b79aeff5b0c28a67427084b74cfefb`.

## Delivered behavior

- Result review separates acceptance from agent activity, checks, source freshness and publication. Missing structured results use attributed observed evidence and can be edited explicitly.
- Project launch recipes preserve command, working directory and destination. Changed managed recipes require an explicit restart. External or unknown processes remain protected.
- Needs you presents actual requests, observed check failures and explicit result review. Cmd-J selects the next decision within the window.
- Status remains unknown when evidence is missing. Waiting does not imply completion. Review request wording and permission scope follow actual provider evidence.
- Commit review names the files, repository, branch and captured bytes. State changes invalidate approval. Normal hooks and signing remain enabled. Publication, index and recovery-history failures have explicit recovery results.
- Finish summarizes acceptance, checks, publication and protected resources. It proposes cleanup without deleting resources. Automatic task archive requires matching merged/current/clean evidence, known history, and complete stopped-session evidence. Restore is durable.
- Cancelled session creation preserves its origin. Missing CLIs show provider-specific setup and a retry inside the launch sheet.

## Review

Specifications received independent checks before implementation. An independent UI stress review, simplification pass and nine-lens code review followed implementation. Supported findings returned to their original authors. A separate reviewer checked the resulting fixes against production source and disposable Git tests.

Review also exposed staged-only source changes and ambiguous binary untracked-entry framing. Both now invalidate captured acceptance, with direct red-to-green tests.

## Local verification

- Final directly affected native batch: **426 tests in 41 suites passed**. It covers status/permissions, launch cancellation and recovery, Finish/archive, results and recipes, attention, migration preservation, preview recovery, immutable commits, terminal management, voice/navigation, command palette and linked review sessions.
- Expanded batch: **485 tests in 46 suites; 482 passed and three failed**. Failures were an approval-response timer and two lazy-browse launch/discovery cases. The two lazy-browse failures also occurred on the clean baseline.
- Isolated follow-up: **21 tests in two suites; 19 passed and two failed**. ApprovalResponseTrackerTests passes; LazyBrowseSessionsLoadingTests still fails `concurrentLaunchesKeepDistinctSessionTerminals` and `codexPendingSessionResolvesFromConfiguredDataPath`. Both failures are reproduced in the clean-base full run. No claim is made that these two failures are only timing failures.
- All six fast packages passed: AgentHubVoice, AgentWorkflowCore, AgentHubCLI, AgentHubGitHub, SimulatorPreview and Storybook.
- Motion guard, shell guard and whitespace checks passed. The configured build lint ran; no project-wide formatting cleanup was attempted.
- Full `make test`: **failed**, exit 2, because the broad Core suite reported timing, timeout and headless failures. The clean base already failed the broad Core run. This attempt also exposed two affected status integration failures; both were corrected and pass in the final 426-test batch. The full gate is not green, and the final focused run is not represented as a full-suite pass.
- Independent exact-source reruns passed all 29 commit-service tests and all six source-service tests.
- Complete Debug macOS app compilation: **BUILD SUCCEEDED**. The configured dependency SwiftLint runs reported zero violations. Artifact: `build/DerivedData/Build/Products/Debug/Workbench.app`.

Build command: `xcodebuild -workspace app/AgentHub.xcodeproj/project.xcworkspace -scheme AgentHub -configuration Debug -destination platform=macOS -derivedDataPath build/DerivedData -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation build`.

No GitHub CI pass is claimed. Human observations and interactive checks remain separate from automated tests.

## Explicit limits

TES-266 real-user measurements remain unmeasured. Automated checks do not establish participant recognition, five-second discovery, one-action comprehension or a 90% launch success rate. The separate output-review validation record contains the observation protocol.

No installed application was replaced. No production terminal, server or worktree was stopped or deleted. No merge or deployment is part of this delivery. Manual keyboard/VoiceOver and live server restart checks remain unperformed. Native layout tests use isolated mock and in-memory fixtures.

Commit ref publication, recovery history and index installation are separate filesystem operations. A crash can require recovery; the service does not promise a cross-file atomic transaction. Unsupported commit states fail explicitly.

Ghostty exposes foreground-process evidence without a complete owned-root PID inventory. Its natural or explicit-close state therefore remains unknown and protected from automatic Finish archive. SwiftTerm can supply complete per-pane owned process evidence. Unknown is never treated as stopped.
