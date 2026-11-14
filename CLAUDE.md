# AgentHub

Native macOS app for monitoring and managing Claude Code and Codex CLI sessions in real-time. Entirely local — no data leaves the machine.

## Tech Stack

- **Platform:** macOS 14.0+ / SwiftUI
- **Language:** Swift (Swift 6.0 tools version, `.v5` language mode)
- **State management:** `@Observable` macro — never use `ObservableObject`
- **Concurrency:** Swift actors, `async/await`, `Task`, `withTaskGroup`
- **Persistence:** UserDefaults (app/UI preferences only), SQLite via GRDB (`SessionMetadataStore` for session/workspace state)
- **File watching:** kqueue-based `DispatchSource` — no polling

## Project Structure

```
app/
  AgentHub/                    # App target (entry point, AppDelegate, ContentView)
  modules/
    AgentHubCore/              # Swift Package — all core logic lives here
      Sources/AgentHubMCPUI/   # Reusable MCP UI resource model and WKWebView renderer
      Sources/AgentHubGlobalSessionPanel/ # Floating global Sessions panel UI/presenter
      Sources/AgentHub/
        Configuration/         # AgentHubProvider, AgentHubConfiguration, environment keys
        Design/                # Tokens/, Components/, Motion/ (new UI); ThemeManager + YAML themes (legacy)
        Intelligence/          # Smart mode / AI orchestration (IntelligenceViewModel)
        Models/                # CLISession, SessionMonitorState, SessionStatus, etc.
        Services/              # File watchers, parsers, git, search, stats, metadata store
        Shell/                 # The new interface: window root, sidebar, session view, overlays (Shell/README.md)
        UI/                    # All SwiftUI views
        Utils/                 # Helpers, extensions, constants
        ViewModels/            # CLISessionsViewModel, MultiSessionLaunchViewModel, etc.
  AgentHubTests/
  AgentHubUITests/
```

## Architecture

### Data Flow

```
~/.claude/projects/{encoded-path}/{sessionId}.jsonl   (Claude sessions)
~/.codex/sessions/{date-path}/                        (Codex sessions)
    → SessionFileWatcher (kqueue DispatchSource, byte-offset incremental reads)
    → SessionJSONLParser (parses JSONL lines into structured state)
    → SessionMonitorState (published via Combine)
    → CLISessionsViewModel (@MainActor, drives UI)
    → SwiftUI Views (MonitoringCardView, etc.)
```

### Provider Abstraction

Both Claude and Codex are supported through shared protocols:

- `SessionMonitorServiceProtocol` — session discovery and repository management
- `SessionFileWatcherProtocol` — real-time file monitoring with state publishing
- `SessionSearchServiceProtocol` — full-text search across sessions

Concrete implementations: `CLISessionMonitorService` / `CodexSessionMonitorService`, `SessionFileWatcher` / `CodexSessionFileWatcher`.

### Environment Injection

`AgentHubProvider` is the central service locator, injected via SwiftUI environment:
```swift
.environment(\.agentHub, provider)
```
`AgentHubModifier` also injects: `statsService`, `displaySettings`, `themeManager`, `runtimeTheme`.

### Key Models

- `CLISession` — Core session entity (id, projectPath, branchName, isWorktree, status, messages)
- `SessionMonitorState` — Real-time state: status, token counts, tool calls, pending approvals
- `SessionStatus` — Enum: `.thinking`, `.executingTool(name:)`, `.waitingForUser`, `.awaitingApproval(tool:)`, `.idle`
- `SelectedRepository` / `CLISessionGroup` / `WorktreeBranch` — Hierarchical grouping
- `OrchestrationPlan` / `OrchestrationSession` — AI-generated parallel task plans

### Key ViewModels

- `CLISessionsViewModel` — Main ViewModel (~1,950 lines), manages all session state, selection, monitoring
- `MultiSessionLaunchViewModel` — Parallel session launcher (manual + smart mode)
- `IntelligenceViewModel` — Calls Claude Code SDK to generate orchestration plans

## Worktree Contract

AgentHub uses native Git linked worktrees and keeps their Git root at the repository root. In monorepos, an `ios/...` or `android/...` task still runs inside a repo-root worktree; the embedded terminal can start from a nested launch directory, but Git, grouping, deletion, and cleanup still operate on the worktree root.

- AgentHub-created worktrees are sibling directories beside the main repository. Do not create repo-local `.worktrees` folders or write `.worktrees/` into `.git/info/exclude`.
- Keep `worktree.path` and `launchPath` separate. `worktree.path` is the registered root used for ownership, sidebar grouping, deletion, cleanup suggestions, and worktree settings. `launchPath` is only the agent's starting cwd inside that root.
- Sparse checkout is the default for launched agent worktrees that start from a tracked subdirectory. Repo-root starts must preserve full-checkout behavior unless sparse was explicitly requested.
- Sparse worktrees must be created with `git worktree add --no-checkout`, configured before materialization, then checked out. Inferred profiles use project markers near the launch path, include shared support paths such as `.agents`, `.claude`, `.claude-plugin`, `scripts/git_hooks_support`, and `scripts/git_support` when those paths exist, and include top-level `gradle` support only when a Gradle marker is detected.
- If a sparse worktree needs more files, expand it with `git sparse-checkout add -- <path>` or the shared expansion helper. Do not disable sparse checkout or create a second full worktree as the first response.
- When code maps a session path back to a worktree, use `WorktreeModuleResolver.bestMatch` or `modulePath` so nested launch paths resolve to the registered worktree root before grouping, cleanup, or deletion.

## Services & Testability

### Protocol-Driven Services

All services must be defined as **protocols (interfaces)** first, with concrete implementations separate. This enables easy mocking and unit testing.

```swift
// Define the interface
protocol SessionMonitorServiceProtocol {
  func discoverSessions(in directory: URL) async throws -> [CLISession]
  func startMonitoring(session: CLISession) async
}

// Concrete implementation
actor CLISessionMonitorService: SessionMonitorServiceProtocol { ... }

// Test mock
final class MockSessionMonitorService: SessionMonitorServiceProtocol { ... }
```

- Every service must have a corresponding protocol — never depend on concrete types directly
- ViewModels and other consumers receive services via protocol types, not implementations
- Use `AgentHubProvider` to wire concrete implementations; tests substitute mocks
- Actors implement protocols for thread-safe I/O services; mocks can be simple classes

### Testing Requirements

- All services and ViewModels **must have unit tests** — code must be well tested
- Use protocol-based mocks to isolate units under test
- Test files live in `AgentHubTests/` and mirror the source structure
- Cover critical paths: session discovery, JSONL parsing, state transitions, file watching lifecycle
- Use `async` test methods for testing actor-based services
- Prefer deterministic tests — inject controlled data rather than relying on file system state

### Running Tests (headless)

**MANDATORY for agents: whenever you change app code under any `Sources/`, run the _targeted_
tests for the affected area before finishing the task, and report real pass/fail.** Do not stop
at "it compiles" — "it builds" is not evidence a test passes. Do not run the whole suite for
every edit; target the code you touched. Run the full suite only before opening/finishing a PR.

- **Targeted run (use this on code changes).** Map source → test (`Services/GitDiffService.swift`
  → `GitDiffServiceTests`) and run only that:
  - Core (`AgentHubCore`): `cd app/modules/AgentHubCore && xcodebuild test -scheme AgentHubCore-Tests -destination 'platform=macOS' -test-timeouts-enabled YES -skipPackagePluginValidation -only-testing:AgentHubTests/<SuiteType>` (repeat `-only-testing:` per suite; `<SuiteType>` is the test `struct` name, not the `@Suite("…")` display string).
  - A sub-module (`AgentHubGitHub`, `Storybook`, `SimulatorPreview`, `AgentHubCLI`): `cd app/modules/<Module> && swift test --filter <TestName>`.
- **Full gate (before a PR, or `/test`): `./scripts/test.sh`** — fast `swift test` packages, then the
  whole `AgentHubCore` xcodebuild suite. Subsets: `./scripts/test.sh core` / `packages`. This is the
  full local gate. **CI (`.github/workflows/test.yml`) gates on the fast packages only** — the
  `AgentHubCore` suite is run locally, not in CI (slow to compile + timing-flaky on CI's older
  Xcode; see `TestQuarantine.md`), so running it locally on your changes is essential. There is
  intentionally **no** git pre-commit/pre-push hook — running tests is the agent's responsibility.
- The `AgentHubCore` tests run via the shared `AgentHubCore-Tests` scheme, driven **from the package
  dir** (`cd app/modules/AgentHubCore`), with per-test timeouts. `swift test` on `AgentHubCore` does
  **not** work (CodeEditSymbols xcassets); use the script / xcodebuild. The app scheme
  (`build-for-testing -scheme AgentHub`) is a **false signal** — it compiles/runs zero package tests.
- swift-testing runs `@Test`s in parallel **off the main thread**; any suite touching AppKit must be `@MainActor`.
- Some tests are quarantined headless (`.disabled("headless-quarantine: …")`) — see `TestQuarantine.md`
  / issue #380 for the open follow-ups; treat skips as known-broken, not passing, and don't re-enable
  without fixing the documented root cause.

### Database Migration Rules

- Read `AccessorySessions.md` before editing accessory terminal panes, sub-session launch/detection, terminal workspace linked-session restore, or `session_relationships`.
- Session/workspace management state belongs in `SessionMetadataStore` / SQLite, not UserDefaults.
- Persistent-state paths (metadata sqlite, `approvals/`, `claims/`, `hooks/`) resolve through `AgentHubApplicationSupport.baseDirectoryURL` — never build `~/Library/Application Support/AgentHub` paths directly. Test processes are automatically sandboxed into a temp directory so no suite can touch real user state; `AGENTHUB_APP_SUPPORT_DIR` overrides explicitly.
- Workspace-state saves are gated on one successful `readWorkspaceState` per run (`canPersistWorkspaceState`). Never treat a failed read as empty state and never bypass the gate in `persistWorkspaceState` — a failed read saved back over the row is how users lose their tracked projects and monitored sessions.
- Do not add `AgentHubDefaults` keys for selected repositories, monitored session IDs, session restore state, repo mappings, terminal workspace state, or terminal/dev-server process cleanup state.
- `managed_processes` is the SQLite authority for app-spawned terminal/dev-server cleanup. Store only process identity/routing metadata needed for cleanup (PID, process group, process start time, kind/provider/session/project context), never prompts, full environment, terminal contents, or other sensitive runtime payloads.
- Never edit, rename, reorder, or delete existing `DatabaseMigrator` migrations. Add a new `vN_*` migration for every schema change.
- Treat the ordered `vN_*` migration identifiers in `SessionMetadataStore` as table versioning. Do not add ad hoc per-table schema version columns unless a table-specific encoded payload requires one.
- Production migrations must preserve existing rows. Do not use broad `delete`, `drop table`, `clearAll()`, or `eraseDatabaseOnSchemaChange` in migrations.
- Any `SessionMetadataStore` schema change must add or update migration-preservation tests that seed the current baseline database and verify all existing metadata still reads back after migration.
- Process cleanup must verify persisted PID identity before terminating. If PID start time/process group no longer matches the row, delete the stale row without killing.
- Process group cleanup is only allowed for groups AgentHub owns. Persist/use a process group only when the child is its own group leader (`pgid == pid`); inherited PGIDs must fall back to PID-only termination.
- Keep launch/crash-recovery cleanup broad, but user-triggered orphan cleanup must be scoped to inactive terminal rows for the relevant provider/PIDs. It must not sweep dev-server rows or active terminals.

## SwiftUI View Guidelines

### Composability

- Views should be **small, focused, and composable** — each view does one thing well
- When a view body exceeds ~40–50 lines, break it into smaller **extracted subviews**
- Prefer creating dedicated component views over using large inline closures

```swift
// Prefer this:
struct MonitoringCardView: View {
  var body: some View {
    VStack {
      StatusHeaderView(status: status)
      ContextWindowBar(usage: usage)
      ToolActivityFeed(tools: tools)
    }
  }
}

// Avoid this: one massive body with hundreds of lines
```

### View Patterns

- Extract repeated UI patterns into reusable components (e.g., `StatusBadge`, `SectionHeader`)
- Use `ViewModifier` for shared styling and behavior (e.g., card backgrounds, hover effects)
- Keep view logic minimal — delegate business logic to ViewModels
- Use `@Environment` for injecting shared dependencies, not init parameters passed through many layers
- Prefer value types (`struct`) for views — never use classes for SwiftUI views
- Use `@Binding` for two-way data flow between parent and child views
- Use descriptive view names that reflect their purpose (e.g., `SessionStatusIndicator`, not `StatusView`)

## Code Style

- **Indentation:** 2 spaces (not tabs)
- Use `@Observable` macro — never `ObservableObject`
- Use `async/await` and actors — never completion handlers
- Services that do I/O are Swift actors (e.g., `CLISessionMonitorService`, `SessionFileWatcher`)
- Use `@MainActor` on ViewModels and UI-bound classes
- UserDefaults preference keys are namespaced under `com.agenthub.` (see `AgentHubDefaults`)

## UI/UX Patterns

### Navigation

The new interface (`Shell/`, see `Shell/README.md`) is the default. `AgentHubApp` reads `AppleShellLaunchFlag` once at launch: unset or YES gives the shell; an explicit NO (Settings › General › New interface, or `-com.agenthub.features.appleShell NO`) gives the legacy `AgentHubOperationsView`. The legacy shell stays behind the flag until P11b deletes it. Design rules: `DESIGN.md`.

- `ShellFrame` has three slots: sidebar (288 pt), a 52 pt title row, and the detail in an inset content panel. No `NavigationSplitView`.
- Title row: destination tabs Sessions, Reviews, Jira, Linear (⌘1–⌘4, with counts), then Search. Appearance and palette are in Settings › Appearance (and the palette's "Switch appearance"), not in the title row.
- Sidebar: one repo → branch → session tree (`Shell/Sidebar/`). Workflows are folded into the branch rows; there is no Workflows screen.
- Per-window state (`WorkbenchShellModel`, `SessionNavigationModel`, `SessionsActionCoordinator`) lives in `ShellRoot`, never in provider singletons.

### Hub Layouts

The shell shows one session: the sidebar's selection (`SessionDetailStateModel`). The four monitoring layouts (Single, List, 2-Column, 3-Column) exist only in the legacy UI.

### Session Cards

In the shell, `SessionDetailView` shows:
- `SessionHeaderView`: title, status glyph and word, actions
- `MonitoringCardContentArea` (shared with the legacy `MonitoringCardView`): Terminal, Chat, Files or Diffs
- For Claude, an approval banner over the terminal (Approve ⌘↩, Deny). It is an overlay, never a sibling, so the PTY never resizes

### Side Panels

`SessionSidePanel` is a trailing panel in a `ResizablePanelContainer` (400 pt, 320–520), toggled with ⌥⌘0. `SidePanelSegments` decides which segments show (Diff, Plan, Edits, Preview or Storybook, GitHub, MCP apps, Measurements, Studio, Artifact, Simulator, …); they render through the shared `SidePanelContentView`. Diff is the compact `SidePanelDiffView`; "Show full diff" opens the legacy `GitDiffView`.

### Web Preview Precedence

- Prefer agent-provided localhost URLs when a session exposes one
- If monitor state is still catching up, recover the latest localhost URL from the session JSONL file before choosing a static preview
- If that external localhost preview fails to load, fall back to static HTML: root `index.html` first, then other discovered HTML files
- Changes to this behavior require unit tests

### Global Session Panel

The floating global Sessions panel is modularized in `AgentHubGlobalSessionPanel` (`app/modules/AgentHubCore/Sources/AgentHubGlobalSessionPanel`).

- Keep panel SwiftUI, AppKit presenter, row sorting, keyboard navigation, and cleanup-suggestion logic in `AgentHubGlobalSessionPanel`.
- `AgentHubCore` owns only shared contracts and routing: `GlobalSessionControlPanelCoordinator`, `GlobalSessionControlPanelPresenting`, hotkey registration, and `GlobalSessionSelectionRouter`.
- `AgentHubProvider` accepts a presenter factory. The app target injects `AppKitGlobalSessionControlPanelPresenter` from the panel module.
- Do not make `AgentHubCore` import `AgentHubGlobalSessionPanel`; that creates a dependency cycle.
- Put panel behavior tests in `AgentHubGlobalSessionPanelTests`.

### Voice (reusable modules)

The voice stack is designed to be droppable into another app. Layering, strictly one-directional:

- **`AgentHubVoice` package** (`app/modules/AgentHubVoice`) — app-agnostic voice infrastructure: `RealtimeVoiceEngine`, audio capture/playback, dictation/STT, `VoiceTool`/`VoiceToolRegistry`, realtime session config builder, OpenAI key handling, `VoiceScreenCaptureService` (+ `VoiceScreenCaptureTools` factory for `list_displays`/`capture_screen`), and the HUD contract (`VoiceHUDHost`, `VoiceHUDConfiguration`, `VoiceHUDPresenting`). Depends only on SwiftOpenAI. Never import AgentHub types here.
- **`AgentHubVoicePanel` target** (same package) — reusable SwiftUI HUD + onboarding (`VoiceOnboardingView`, `VoiceOption`) + `AppKitVoiceHUDPresenter`. Depends only on `AgentHubVoice`; branding and UserDefaults keys arrive via `VoiceHUDConfiguration` — never hardcode an app's name or preference keys in this target.
- **`AgentHubCore`** — the AgentHub-specific glue: `VoiceAgentToolExecutor`, `VoiceToolCatalog` (session tools; appends the capture tools from the factory), target resolver, completion watcher, transcript reader, `VoiceControlCoordinator`, settings UI, and `AgentHubVoiceHUDHost` (the `VoiceHUDHost` adapter) plus `VoiceHUDConfiguration.agentHub`. Core imports both voice products; the voice package must never import core.

To reuse voice in another app: depend on the `AgentHubVoice` package, implement `VoiceHUDHost`, supply a `VoiceHUDConfiguration`, and present `AppKitVoiceHUDPresenter` — plus your own tool catalog for app-specific tools.

### MCP UI

`AgentHubMCPUI` (`app/modules/AgentHubCore/Sources/AgentHubMCPUI`) is the reusable MCP UI layer — the `AgentHubMCPUIResource` model and the WKWebView renderer/bridge.

- Use `AgentHubMCPUIResource` for MCP app resources. The default MIME profile is `text/html;profile=mcp-app`.
- Use `AgentHubMCPUIResourceView` or `AgentHubMCPUIWebView` to render MCP UI HTML in-app.
- Feature-specific builders should live with the feature and emit `AgentHubMCPUIResource`; do not recreate local resource structs or WKWebView wrappers.
- Escape generated HTML with `AgentHubMCPUIHTML.escape(_:)`.

### MCP Apps (agent-driven rendering)

AgentHub renders MCP app UIs an agent produces during a session (e.g. an excalidraw diagram) in a dedicated side panel — driven by the agent's tool calls, not by proactive discovery. Read **`MCPApps.md`** before editing MCP app detection, resolution, rendering, or consent: the parsers' `detectedMCPAppInvocations`/`detectedMCPAppResources` capture, `CLISessionsViewModel.ensureMCPAppRenderItems`/`mcpAppRenderItems`, `MCPAppSidePanelView`, `MCPAppDiscoveryService` (on-demand gateway), or the `AgentHubMCPUIResourceView` bridge push. `MCPApps.md` also tracks the feature's current state and remaining gaps.

### Storybook Mode

When a project has Storybook configured, the Preview button is replaced with a Storybook button — never both. Routing is gated by `WebPreviewMode { .app, .storybook }`; the storybook server runs under the compound `DevServerManager` key `"{sessionId}:storybook"` alongside the primary app server. Detection lives in the standalone `Storybook` Swift module (`app/modules/Storybook/`, pure Foundation). See **Storybook** in `README.md` for detection rules, script-port handling, and the prompt auto-accept.

### Simulator Preview (live in-app iOS Simulator)

For Xcode projects, a single **Simulator** button opens a side panel that mirrors a booted iOS Simulator live and forwards mouse/keyboard back to it (the old per-card management-sheet button is deprecated; the sheet is reachable from the panel header). An **Annotate** mode reads the simulated app's accessibility tree (`SimulatorAXInspector`, idb-style `AXPTranslator` bridge — private framework, no TCC prompts), overlays element frames with hover inspection, and drops numbered pins bound to elements (role/label/identifier/frame); pins are sent to the agent as a composed element-aware prompt plus a pin-stamped screenshot, through the same terminal-prompt path as web-preview feedback. Pins degrade to positional coordinates when element data is unavailable. Capture + input live in the standalone `SimulatorPreview` module (`app/modules/SimulatorPreview/`), which taps the simulator framebuffer IOSurface and injects Indigo HID events via the private CoreSimulator/SimulatorKit frameworks — **no Screen Recording/Accessibility prompts, no network, nothing persisted**. Falls back to public `simctl io screenshot` polling (view-only) when those frameworks are unavailable. Device lifecycle reuses the existing `SimulatorService`. Read **`SimulatorPreview.md`** before editing the module, `SimulatorPreviewSidePanelView`, the `SidePanelContent.simulator` case/routing, the `onShowSimulatorPreview` card callback, or `AgentHubProvider.simulatorStreamService` — it documents the privacy contract and the private-API risk.

The panel also has **hot reload + a Previews tab** (Live | Previews toggle, ● Hot reload pill): saved Swift files are hot-swapped into the running app by an inserted [InjectionLite] dylib, and matching SwiftUI previews render through a generated preview-host dylib built on [SnapshotPreviews]'s core — both produced once from a generated, exact-pinned wrapper package (`HotReloadHostPackage`) and inserted at launch via `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`. Structural changes fall back to an incremental rebuild; the pill never lies. Read the **Hot reload + Previews tab** section of `SimulatorPreview.md` before editing anything named `HotReload*`, `PreviewHost*`, or `SimulatorHotReloadController`. Two hard-won invariants: never launch hot-reload consoles with `--console-pty` (simctl forwards signals — stopping the console would kill the user's app), and never insert SnapshotPreviews' stock `Snapshotting` dylib (its render window covers the running app — the "blank simulator" failure).

Agent sessions use XcodeBuildMCP for simulator build/run, screenshots, and UI automation; AgentHub bootstraps that MCP server for Xcode project launches with the current workspace/project path, saved simulator UDID when available, and simulator verification guidance for Claude/Codex. The bootstrap is gated by a default-on setting (`AgentHubDefaults.xcodeBuildMCPEnabled`) and a Node/npx preflight (`XcodeBuildMCPPreflight`), runs a pinned npm version (never `@latest`), and the guidance prompt is only injected when the bootstrap is attached. AgentHub no longer exposes bundled agent-facing simulator control tools; manual simulator recording remains panel-only. While the panel mirrors, the real Simulator.app window is ⌘H-hidden (`SimulatorAppHider`, default-on setting) and panel launches skip foregrounding it (`foregroundSimulatorApp: false`). Read the **Agent-driven runs & the verification loop**, **Auto Build & Run**, and **Hiding the real Simulator.app** sections of `SimulatorPreview.md` before editing XcodeBuildMCP bootstrap/guidance (`CLICommandConfiguration`, `EmbeddedTerminalLaunchBuilder`, `SimulatorAgentGuidance`), `SimulatorPanelRunFlow`, recording UI, or simulator side-panel routing.

[InjectionLite]: https://github.com/johnno1962/InjectionLite
[SnapshotPreviews]: https://github.com/getsentry/SnapshotPreviews

### Measurements Panel

Measurements an agent produced during a session (a claim, the chart/table behind it, the query, and caveats) render in a dedicated side panel. The agent files them with the bundled `agenthub_record_measurement` MCP tool and discovers existing ones with `agenthub_list_measurements`; AgentHub draws the chart from a data spec with Swift Charts — agent-authored markup never reaches the panel.

Measurements are scoped to the **project**, not the session: they outlive the conversation that produced them and are shared across every session and both providers, with worktrees rolling up to their parent repo. `↻` re-runs a measurement's stored query *through the agent* (AgentHub never executes it) and accumulates each run into a capped history so a tracked metric shows its trend. The CLI reads measurements through a JSON index the app republishes (`MeasurementIndexStore`) and must not open the app's SQLite database.

Read **`Measurements.md`** before editing anything named `Measurement*`, the `SidePanelContent.measurements` case, `agenthub_record_measurement` / `agenthub_list_measurements`, or the `session_measurements` table.

### Artifact Panel

Artifacts an agent published to claude.ai during a session (`/design` canvases, reports, mockups) open in a dedicated side panel. Detection is passive and read-only, on the same rails as localhost web preview: `SessionJSONLParser` files an artifact from the `Artifact` tool's publish result (which carries the title and source path), from the `frame-link` entry Claude Code writes alongside it, or from a bare artifact URL in the transcript — into `SessionMonitorState.detectedArtifacts`. An **Artifact** button appears in the card header only once one has been detected, and toggles `SidePanelContent.claudeArtifact` open/closed (renamed from `.artifact` so it is never confused with the Studio panel below).

- **Claude only.** `CodexSessionJSONLParser` never files artifacts, and the card gates the button on `providerKind == .claude`.
- Artifacts are keyed by the id in the URL, so a republish updates the existing entry and bumps `revision` — which is what makes an open panel reload — instead of appending a duplicate. The canonical URL drops query/fragment (`?via=auto_preview` is provenance, not identity).
- `ArtifactWebView` uses the **default (persistent)** website data store: artifact pages are private to the signed-in account, so the sign-in has to survive a panel close and a relaunch. Links leaving claude.ai open in the user's browser. A signed-out load lands on Anthropic's sign-in page (`ClaudeArtifactURLDetector.isSignInURL`); the panel banners it as Anthropic's, not AgentHub's, and tells the user to sign in **in the panel**. A browser session is a different cookie jar and never carries over, so that banner must not offer an open-in-browser escape.
- Detection changes belong in `ClaudeArtifactURLDetector` and need unit tests.

### Studio Panel

Artifacts and design canvases an agent renders during a session (`agenthub_artifact` for one HTML document, `agenthub_design` for N variants of one component on an infinite canvas) open in a dedicated **Studio** side panel, served from AgentHub's own in-process loopback server and annotated with the Canvas inspector overlay. Works for Claude and Codex. Read **`AgentHubStudio.md`** before editing anything named `Studio*`, the `SidePanelContent.studio` case, the three `agenthub_artifact` / `agenthub_design` / `agenthub_list_artifacts` tools, or the `studio_artifacts` table. The short version: the agent renders into a scratch surface, never into the project — Send re-files by id and forbids project edits; Promote… is the only action that asks for code; every variant's CSS is scoped at the tool boundary (`StudioCSSScoper` in `AgentHubCLIKit`), artboards are DOM sections, never iframes, because the inspector bridge is main-frame-only, Tweaks are one shared `props` schema per canvas (CSS custom properties on every artboard), never per variant, and agents are steered to the tools by `StudioAgentGuidance` (system prompt, default-on) plus the bundled `agenthub-studio` skill.

### Command Palette

`WorkbenchCommandPalette` (`Shell/Overlays/`, 640 pt) opens on ⌘K or the title-row Search field: sessions, destinations and actions. Rows come from `UI/CommandPaletteEntries.swift`. The legacy UI keeps `CommandPaletteView`.

### Keyboard Shortcuts

New interface (one table, `Shell/ShellShortcuts.swift`, bound by `ShellCommands` and shown in the palette): ⌘K (palette), ⌘N (new session sheet), ⌘1–⌘4 (Sessions, Reviews, Jira, Linear), ⌃⌘S (sidebar), ⌥⌘0 (side panel), ⇧⌘R (resume session by ID), ⌥⌘A (archive current session), ⌘↩ (approve while the banner shows), Escape (dismiss). Legacy UI only: Cmd+B (sidebar), Cmd+[/] (navigate sessions), Cmd+\ (focus mode).

## Dependencies

| Package | Purpose |
|---|---|
| Canvas | Web preview element inspection and prompt/context capture |
| ClaudeCodeSDK | Claude Code CLI integration |
| PierreDiffsSwift | Split-pane diff rendering |
| SwiftTerm (local fork) | PTY terminal emulation |
| swift-markdown-ui | Markdown rendering |
| GRDB.swift | SQLite ORM for session metadata |
| HighlightSwift | Syntax highlighting |
| Yams | YAML parsing for themes |
| Sparkle | Auto-updates with EdDSA verification |

## Terminal Enhancements

The embedded terminal uses a fork of SwiftTerm (`jamesrochabrun/SwiftTerm`, branch `agenthub`) with modular additions in `Sources/SwiftTerm/AgentHub/`. All new code lives in that directory to minimize merge conflicts with upstream.

### Features

| Feature | Shortcut | Description |
|---------|----------|-------------|
| **Search** | `Cmd+F` | Built-in find bar with regex, case-sensitive, whole-word toggles |
| **Cmd+Click URLs** | `Cmd+Click` | Opens plain URLs in browser (no OSC 8 required) |
| **Cmd+Click file paths** | `Cmd+Click` | Opens file in inline Files panel (configurable: AgentHub / VS Code / Xcode) |
| **Theme integration** | Automatic | New interface: follows the Workbench palette and appearance (`TerminalPaletteResolver`). Legacy: background and cursor follow the YAML theme |
| **OSC 133 tracking** | — | Semantic prompt boundary tracking (foundation for future features) |

### Fork Architecture

- **Branch:** `agenthub` — all additions live here; `main` tracks upstream
- **New files:** `Sources/SwiftTerm/AgentHub/` — PlainURLDetection, FilePathDetection, SemanticPromptTracker, MarkStore, SmartSelectionEngine
- **Upstream changes:** Minimal — `cellDimension` and `displayBuffer` exposed as public, `requestOpenFile` delegate added
- **Merge upstream:** `git fetch upstream && git merge upstream/main` into `agenthub`

### Settings

- **Open files with** — Choose AgentHub (inline), VS Code, or Xcode for Cmd+Click file paths
- **Terminal colors** — YAML themes can define `terminal.background` and `terminal.cursor` hex colors

## Common Commands

```bash
# Build (via Xcode)
xcodebuild -workspace app/AgentHub.xcodeproj/project.xcworkspace -scheme AgentHub build

# Run tests
xcodebuild -workspace app/AgentHub.xcodeproj/project.xcworkspace -scheme AgentHub test
```

## Session Data Paths

- Claude sessions: `~/.claude/projects/{encoded-path}/{sessionId}.jsonl`
- Claude history: `~/.claude/history.jsonl`
- Claude stats: `~/.claude/stats-cache.json`
- Codex sessions: `~/.codex/sessions/{date-path}/`
- Codex history: `~/.codex/history.jsonl`
- Custom themes: `~/Library/Application Support/AgentHub/Themes/`
- Approval hook script: `~/Library/Application Support/AgentHub/hooks/agenthub-approval.sh`
- Approval sidecars: `~/Library/Application Support/AgentHub/approvals/{sessionId}.jsonl`
- Session claims: `~/Library/Application Support/AgentHub/claims/{sessionId}`
- Session metadata/workspace DB: managed by `SessionMetadataStore` via GRDB

## Approval Detection (Claude only)

Claude Code buffers `tool_use` blocks until the turn commits, so JSONL alone can't surface pending approvals during the prompt. Hook events write to a sidecar directory we watch: `PermissionRequest` marks real approval prompts, while `PreToolUse` records observed tool/mode state so `auto` mode changes can suppress false pending approvals mid-session. JSONL stays primary and the hook fills the gap. Codex has no equivalent mechanism — `CodexSessionFileWatcher` hardcodes `pendingToolUse: nil`.

- `ClaudeHookInstaller` — writes our hook entry into `{project}/.claude/settings.local.json`. Driven by the repositories subscription (Claude Code reads settings once at session start). Preserves every other key and every non-AgentHub hook entry.
- `ClaudeHookSidecarWatcher` — per-session kqueue watcher over `approvals/`, merges into `ParseResult.pendingToolUses` at `buildMonitorState`.
- `ApprovalClaimStore` — claim markers gate the script so external Terminal sessions in tracked worktrees are silent no-ops.
- `HookPendingStalenessFilter` — drops hook entries that JSONL has already moved past (100ms epsilon).

**Invariants when editing this area:** only `.claude/settings.local.json` is ever written inside a user's repo (never `.claude/hooks/`, never `.gitignore`); our merge identifies its own entry by the absolute script path; launch reconcile and terminate flush both block on a semaphore so AppKit can't kill cleanup mid-flight.

## GitHub PR/CI Observation

GitHub PR/check monitoring is documented in `GitHubMonitor.md`. Read that file before changing `GitHubPRObservationService`, `GitHubViewModel` observation paths, `SessionGitHubQuickAccessViewModel`, session-row GitHub status, or sidebar refresh behavior.

The short version: GitHub observation is a shared actor service in `AgentHubGitHub`, injected through `AgentHubProvider.gitHubPRObservationService`. UI surfaces subscribe to target snapshots instead of polling independently. Current-branch rows only render GitHub state when a PR exists; no-PR branches should remain visually quiet. Initial refresh is delayed and bounded so GitHub checks do not affect app launch time.

## Git Diff Loading (performance)

`AgentHubGitDiff` has two backends. **libgit2** (`LibGit2DiffBackend`) is the default and is faster than the `git` CLI on normal repos. **Native git** (`GitDiffService.nativeChangedFiles`) is only used for `.unstaged` and `.staged` listing on *large* worktrees, where libgit2's single-threaded `git_diff_index_to_workdir` (per-file stats, no fsmonitor/untracked-cache) is dramatically slower than native git.

- **Large-worktree gate** — `GitDiffService` routes `.unstaged`/`.staged` listing to native git when `.git/index > GitDiffService.defaultLargeWorktreeIndexByteThreshold` (~4 MB ≈ tens of thousands of tracked files). Threshold is injectable via `init` for tests/tuning (tests force the gate with `largeWorktreeIndexByteThreshold: 0`). The native list path mirrors libgit2 output (status, renames, line counts via `--name-status -z` + `--numstat -z`) — kept green by a parity test.
- **Never gate `.branch`** — tree↔tree comparison is already fast in libgit2.
- **Cheap-first ordering** — `GitDiffView` auto-select and `DiffAvailabilityService` probe `branch → staged → unstaged` so the expensive workdir scan runs last; the picker tab order (`DiffMode.allCases`) follows the same cost order. `DiffMode` declaration order is the single source of truth.
- **Untracked floor** — the `.unstaged` tab on an actively-modified large worktree still costs a few seconds (untracked enumeration). The untracked cache can't persist while an agent writes to the worktree; only fsmonitor would fix it. **Do not** write `core.untrackedCache`/`core.fsmonitor` to the user's repo — measured as a no-op there and it mutates user repo state.
- **Benchmark** — `swift run --package-path app/modules/AgentHubCore -c release DiffBench [path]` (the `DiffBench` executable target; not shipped in the app).

## Important Patterns

- File watchers use byte-offset tracking to read only new JSONL lines (never re-read entire files)
- Combine publishers bridge actor-isolated services to `@MainActor` ViewModels
- `Task.detached` is used for file I/O off the actor's isolation context
- `withTaskGroup` for parallel worktree detection and metadata reading
- AgentHub-created worktrees are sibling directories beside the main repository. Do not create a repo-local `.worktrees` folder or write `.worktrees/` into `.git/info/exclude`.
- Terminal PTY state is preserved across pending-to-real session transitions
- `TerminalProcessRegistry` tracks child PIDs for cleanup on app termination
- Theme system: built-in themes (Claude, Codex, Bat, Xcode) + YAML hot-reload via `ThemeFileWatcher`
- Approval notifications: `ApprovalNotificationService` sends macOS alerts when tools await confirmation

## Layout-Loop Crash (open, first seen 2026-11-13)

- **Symptom:** the window freezes for ~5 s, then the app quits. The crash report shows `EXC_BREAKPOINT` in `+[NSApplication _crashOnException:]`, thrown by `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]`. The log text is "…already had more Update Constraints in Window passes than there are views in the window". The loop: `-[NSSplitView setFrameSize:]` → KVO → `NSHostingView.invalidateSafeAreaInsets` → `setNeedsUpdateConstraints`, again and again.
- **Known so far:** four crashes on 2026-11-13 (09:31, 13:12, 13:16, 13:21), first in the first build with that day's UI pass. The last three have breadcrumbs: each loop starts under 0.5 s after `tab: Reviews`, from Workflows and from Sessions, also on the first Reviews visit after launch. From 13:12 every Reviews visit crashed. Window sizes: 1885 × 1099, 2560 × 1410, 2560 × 1345.
- **Ruled out** in stand-alone copies of the layouts (none looped): split-pane minimums wider than the window, `.toolbar(removing: .sidebarToggle)`, tab switching, sidebar toggling, the Sessions `GeometryReader` sidebar width, MarkdownUI pull-request bodies, and window zoom.
- **Also ruled out (2026-11-13, second pass):** the real `GitHubReviewsView` with the saved 16-row queue does not loop in the test host, and the real app does not loop when run with an empty `AGENTHUB_APP_SUPPORT_DIR` (same saved queue, active key window, also with two faked linked sessions). So the loop needs real session/workspace state that is not found yet.
- **Time clue:** the three afternoon crashes came 9 to 18 minutes after two Claude review sessions were started from Reviews (13:03), so those sessions were probably still working. Later the same day (14:17 to 14:25, one resolved and two pending links, sessions idle or starting) Reviews opened several times without a loop, also with the capture attached. Suspect state that only exists while a linked session is active.
- **Unproven lead:** `WorkspaceSearchField` in the Reviews header can take focus when the tab opens. Its focus fade (`.animation(…, value: isFocused)`) is then the only animation running at the moment the loop starts.
- **Trap when testing:** in a hidden or occluded window (every `xctest` window: `isKeyWindow` and `occlusionState.visible` are false) any SwiftUI animation spins thousands of constraint passes per second. That is not this bug. Count passes per run-loop turn (the real loop exceeds the view count in one turn), or look for AppKit's own "has continued for 300 iterations" log line.
- **Capture the culprit:** attach before opening Reviews: `lldb -b -p $(pgrep -x Workbench) -o "command script import scripts/capture_layout_loop.py" -o "capture_loop /tmp/layout-loop-capture.txt" -o continue`. When AppKit throws, the script writes the backtrace and every view that is still dirty (class, frame, parent), then detaches. The class names of the `NSHostingView<…>` entries name the SwiftUI content that loops. It is read-only; the app still quits afterwards.
- **Next time:** `MainThreadStallMonitor` logs the last 20 breadcrumbs with the freeze: tabs, review selection, double-clicks with the view hit, and window resize, zoom, display and full-screen changes (`UIEventBreadcrumbs`). Read them with `/usr/bin/log show --last 2h --predicate 'process == "Workbench" AND (category == "Performance" OR eventMessage CONTAINS "Update Constraints" OR eventMessage CONTAINS "has continued for")'`. Call `/usr/bin/log` by its full path, because a shell function named `log` can hide it and return nothing. At the limit, AppKit also writes `[com.apple.AppKit:DisplayCycle]` lines with the window frame.
- When you add a navigation or selection surface, add a `MainThreadStallMonitor.breadcrumb(...)` for it.

### Rules for new UI work (shell)

- **No split views** in the shell path: no `NavigationSplitView`, `HSplitView`, `VSplitView`, `NSSplitView` or `.inspector`. Use a plain `HStack` with fixed widths, or `ResizablePanelContainer`. Trailing panels (side panel, Reviews and Sprint detail) are fixed-width `HStack` children.
- **No `NSToolbar`, no `.toolbar` on the shell window.** With a toolbar, AppKit sends a click under the titlebar to the content only inside the region SwiftUI reports as opaque, and SwiftUI leaves the title row's controls out of it once the content has composited layers (clip, shadow): every click in the row became a window drag (release blocker, 2026-11-14; `Shell/README.md`, "Title row clicks"). The sidebar toggle is a SwiftUI overlay (`ShellWindowControls`). `ShellTitleBarHitTests` clicks every title-row control through `NSWindow.sendEvent`; run it after any change to the title row, `ShellFrame` or the window style.
- **The top safe area is ignored once, in `ShellFrame`.** Layout starts at the window's top edge and never reads the inset. No other content ignores the top safe area; only backgrounds may.
- **No `GeometryReader` widths.** No size read from geometry may feed the frame of an ancestor or sibling. If one is needed, use `onGeometryChange` with rounding, an equality check and hysteresis.
- **Narrow widths use `ViewThatFits`**, not measured widths: the destination tabs fall back to icon + count, then icon only; the Reviews table drops columns.
- **Animations inside chrome** run in a fixed `.fixedSize()` frame with no intrinsic-size change. No `matchedGeometryEffect` in the title row.
- **Minimum widths** add up to no more than `ShellLayout.windowMinWidth` (900): sidebar 288 + panel inset + the destination's content minimum (`ReviewsLayoutTests`, `SessionDetailReviewTests`).

## Git Commits

- Never add "Co-Authored-By: Claude" or any Claude co-author line
