import ClaudeCodeClient
import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Claude launch environment", .timeLimit(.minutes(1)))
@MainActor
struct ClaudeLaunchEnvironmentTests {
  private let disableKey = "CLAUDE_CODE_DISABLE_AGENT_PROGRESS_SUMMARIES"
  private let extraValue = "quote'value • 日本語\nsecond line"

  @Test("Summary preference persists and takes precedence without changing custom values")
  func preferencePersistsAndPreservesCustomValues() throws {
    let suite = EphemeralDefaultsSuite(prefix: "AgentHubTests.ClaudeLaunch")
    defer { suite.cleanUp() }
    let variables = [
      CLIEnvironmentVariable(name: disableKey, value: "custom"),
      CLIEnvironmentVariable(name: "AGENTHUB_TEST_EXTRA", value: extraValue)
    ]
    CLIEnvironmentOverrides.save(variables, defaults: suite.defaults)
    #expect(CLIEnvironmentOverrides.environment(for: .claude, defaults: suite.defaults)[disableKey] == "1")

    suite.defaults.set(true, forKey: AgentHubDefaults.claudeAgentProgressSummariesEnabled)
    let reopened = try #require(UserDefaults(suiteName: suite.suiteName))
    #expect(CLIEnvironmentOverrides.environment(for: .claude, defaults: reopened)[disableKey] == "0")
    #expect(CLIEnvironmentOverrides.environment(for: .claude, defaults: reopened)["AGENTHUB_TEST_EXTRA"] == extraValue)
    #expect(CLIEnvironmentOverrides.variables(defaults: reopened) == variables)

    reopened.set(false, forKey: AgentHubDefaults.claudeAgentProgressSummariesEnabled)
    #expect(CLIEnvironmentOverrides.environment(for: .claude, defaults: suite.defaults)[disableKey] == "1")
  }

  @Test("Codex and generic shells preserve the existing custom environment")
  func otherProvidersKeepExistingEnvironment() {
    let suite = EphemeralDefaultsSuite(prefix: "AgentHubTests.ClaudeLaunch")
    defer { suite.cleanUp() }
    for provider: SessionProviderKind? in [nil, .codex] {
      #expect(CLIEnvironmentOverrides.environment(for: provider, defaults: suite.defaults)[disableKey] == nil)
    }
    CLIEnvironmentOverrides.save([
      CLIEnvironmentVariable(name: disableKey, value: "user-choice"),
      CLIEnvironmentVariable(name: "AGENTHUB_TEST_EXTRA", value: extraValue)
    ], defaults: suite.defaults)
    suite.defaults.set(true, forKey: AgentHubDefaults.claudeAgentProgressSummariesEnabled)
    for provider: SessionProviderKind? in [nil, .codex] {
      let environment = EmbeddedTerminalLaunchBuilder.makeProcessEnvironment(
        additionalPaths: [], agentHubCLIPath: nil, providerKind: provider, defaults: suite.defaults
      )
      #expect(environment[disableKey] == "user-choice")
      #expect(environment["AGENTHUB_TEST_EXTRA"] == extraValue)
    }
  }

  @Test("SwiftTerm and Ghostty launches apply the preference to new and resumed Claude processes")
  func embeddedLaunchesCaptureEnvironment() throws {
    let fixture = try LaunchCaptureFixture()
    defer { fixture.cleanUp() }
    for enabled in [false, true] {
      fixture.configure(enabled: enabled, customDisableValue: enabled ? "1" : "0", extra: extraValue)
      for sessionID: String? in [nil, "pending-capture", "resumed-capture"] {
        let launch = try EmbeddedTerminalLaunchBuilder.cliLaunch(
          sessionId: sessionID,
          projectPath: fixture.directory.path,
          cliConfiguration: fixture.configuration(mode: .claude),
          initialPrompt: nil,
          dangerouslySkipPermissions: false,
          permissionModePlan: false,
          worktreeName: nil,
          metadataStore: nil,
          agentHubCLIPath: "",
          installAgentHubWorktreeSkill: {},
          xcodeBuildMCPEnabled: false,
          studioGuidanceEnabled: false,
          codexGlobalApprovalPolicy: nil,
          defaults: fixture.suite.defaults
        ).get()
        let swiftTermEnvironment = Dictionary(uniqueKeysWithValues: launch.swiftTermEnvironment.map { entry in
          let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          return (String(parts[0]), String(parts[1]))
        })
        try fixture.runShell(launch.shellCommand, environment: swiftTermEnvironment)
        #expect(try fixture.read("flag") == (enabled ? "0" : "1"))
        #expect(try fixture.read("extra") == extraValue)
        #expect(try fixture.read("terminal") == "SwiftTerm")

        try fixture.runShell(launch.ghosttyCommand, environment: launch.environment)
        #expect(try fixture.read("flag") == (enabled ? "0" : "1"))
        #expect(try fixture.read("extra") == extraValue)
        if sessionID == "resumed-capture" {
          let arguments = try fixture.read("arguments").components(separatedBy: "\n")
          #expect(arguments.contains("-r"))
          #expect(arguments.contains("resumed-capture"))
          #expect(!arguments.contains("--model"))
          #expect(!arguments.contains("--effort"))
        }
      }
    }
  }

  @Test("Terminal scripts scope the preference to the Claude command")
  func terminalScriptsPreserveOuterEnvironment() throws {
    let fixture = try LaunchCaptureFixture()
    defer { fixture.cleanUp() }
    for enabled in [false, true] {
      for customValue: String? in [nil, "user-choice"] {
        fixture.configure(enabled: enabled, customDisableValue: customValue, extra: extraValue)
        for sessionID: String? in [nil, "resumed-capture"] {
          let args = fixture.configuration(mode: .claude).argumentsForSession(sessionId: sessionID, prompt: nil)
          let invocation = ([fixture.executable.path] + args).map(shellQuote).joined(separator: " ")
          let command = TerminalLauncher.commandWithLaunchEnvironment(
            invocation, provider: .claude, defaults: fixture.suite.defaults
          )
          let script = TerminalLauncher.terminalScriptContent(
            command: command + "\nprintf '%s' \"$CLAUDE_CODE_DISABLE_AGENT_PROGRESS_SUMMARIES\" > \"$AGENTHUB_TEST_CAPTURE_PATH/outer\"",
            defaults: fixture.suite.defaults
          )
          var inherited = ProcessInfo.processInfo.environment
          inherited[disableKey] = "inherited-choice"
          try fixture.runShell(script, environment: inherited)
          #expect(try fixture.read("flag") == (enabled ? "0" : "1"))
          #expect(try fixture.read("outer") == (customValue ?? "inherited-choice"))
          #expect(try fixture.read("extra") == extraValue)
        }
      }
    }
  }

  @Test("Codex terminal scripts keep user environment values")
  func codexTerminalScriptsPreserveEnvironment() throws {
    let fixture = try LaunchCaptureFixture()
    defer { fixture.cleanUp() }
    fixture.configure(enabled: false, customDisableValue: "user-choice", extra: extraValue)
    let command = TerminalLauncher.commandWithLaunchEnvironment(
      shellQuote(fixture.executable.path), provider: .codex, defaults: fixture.suite.defaults
    )
    let script = TerminalLauncher.terminalScriptContent(command: command, defaults: fixture.suite.defaults)
    try fixture.runShell(script, environment: ProcessInfo.processInfo.environment)
    #expect(try fixture.read("flag") == "user-choice")
    #expect(try fixture.read("extra") == extraValue)
  }

  @Test("Background session processes read the setting on each launch")
  func backgroundProcessesCaptureEnvironment() async throws {
    let fixture = try LaunchCaptureFixture()
    defer { fixture.cleanUp() }
    for enabled in [false, true] {
      fixture.configure(enabled: enabled, customDisableValue: enabled ? "1" : "0", extra: extraValue)
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        TerminalLauncher.runSessionInBackground(
          "resumed-capture",
          cliConfiguration: fixture.configuration(mode: .claude),
          projectPath: fixture.directory.path,
          prompt: "capture",
          onOutput: { _ in },
          onComplete: { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
          },
          defaults: fixture.suite.defaults
        )
      }
      #expect(try fixture.read("flag") == (enabled ? "0" : "1"))
      #expect(try fixture.read("extra") == extraValue)
      #expect(try fixture.read("arguments").contains("resumed-capture"))
    }
  }

  @Test("A reused tweak runner applies Claude changes and preserves Codex values")
  func tweakProcessesCaptureEnvironment() async throws {
    let fixture = try LaunchCaptureFixture()
    defer { fixture.cleanUp() }
    let runner = TweakAgentProcessRunner(defaults: fixture.suite.defaults)
    for enabled in [false, true] {
      fixture.configure(enabled: enabled, customDisableValue: enabled ? "1" : "0", extra: extraValue)
      try await runner.run(
        prompt: "capture", systemPrompt: "capture", workingDirectory: fixture.directory.path,
        cliConfiguration: fixture.configuration(mode: .claude), activityHandler: {}
      )
      #expect(try fixture.read("flag") == (enabled ? "0" : "1"))
      #expect(try fixture.read("extra") == extraValue)
    }
    fixture.configure(enabled: false, customDisableValue: "user-choice", extra: extraValue)
    try await runner.run(
      prompt: "capture", systemPrompt: "capture", workingDirectory: fixture.directory.path,
      cliConfiguration: fixture.configuration(mode: .codex), activityHandler: {}
    )
    #expect(try fixture.read("flag") == "user-choice")
  }

  @Test("A reused Claude client reads the preference for each process")
  func reusedClientCapturesPreferenceChanges() async throws {
    let fixture = try LaunchCaptureFixture(drainInput: true)
    defer { fixture.cleanUp() }
    let defaults = fixture.suite.defaults
    let client = ClaudeCLIClient(
      command: fixture.executable.lastPathComponent,
      additionalPaths: [fixture.directory.path],
      environmentOverridesProvider: { CLIEnvironmentOverrides.environment(for: .claude, defaults: defaults) }
    )
    for enabled in [false, true] {
      fixture.configure(enabled: enabled, customDisableValue: enabled ? "1" : "0", extra: extraValue)
      let subscription = LaunchCaptureSubscription()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        subscription.cancellable = client.runStreamingPrompt(
          prompt: "capture", workingDirectory: fixture.directory.path, systemPrompt: nil,
          permissionMode: nil, disallowedTools: nil, model: nil
        ).sink(receiveCompletion: { completion in
          subscription.cancellable = nil
          switch completion {
          case .finished: continuation.resume()
          case .failure(let error): continuation.resume(throwing: error)
          }
        }, receiveValue: { _ in })
      }
      #expect(try fixture.read("flag") == (enabled ? "0" : "1"))
      #expect(try fixture.read("extra") == extraValue)
    }
  }
}

private final class LaunchCaptureSubscription: @unchecked Sendable {
  var cancellable: AnyCancellable?
}

private func shellQuote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private struct LaunchCaptureFixture {
  let suite = EphemeralDefaultsSuite(prefix: "AgentHubTests.ClaudeLaunchCapture")
  let directory: URL
  let executable: URL

  init(drainInput: Bool = false) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-launch-capture-\(UUID().uuidString)")
    executable = directory.appendingPathComponent("capture-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = """
    #!/bin/sh
    printf '%s' "${CLAUDE_CODE_DISABLE_AGENT_PROGRESS_SUMMARIES-unset}" > "$AGENTHUB_TEST_CAPTURE_PATH/flag"
    printf '%s' "$AGENTHUB_TEST_EXTRA" > "$AGENTHUB_TEST_CAPTURE_PATH/extra"
    printf '%s' "$TERM_PROGRAM" > "$AGENTHUB_TEST_CAPTURE_PATH/terminal"
    printf '%s\\n' "$@" > "$AGENTHUB_TEST_CAPTURE_PATH/arguments"
    \(drainInput ? "cat >/dev/null" : "")
    printf '%s\\n' '{"type":"result","subtype":"success","result":"captured"}'
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  func configure(enabled: Bool, customDisableValue: String?, extra: String) {
    suite.defaults.set(enabled, forKey: AgentHubDefaults.claudeAgentProgressSummariesEnabled)
    var variables = [
      CLIEnvironmentVariable(name: "AGENTHUB_TEST_CAPTURE_PATH", value: directory.path),
      CLIEnvironmentVariable(name: "AGENTHUB_TEST_EXTRA", value: extra)
    ]
    if let customDisableValue {
      variables.append(CLIEnvironmentVariable(name: "CLAUDE_CODE_DISABLE_AGENT_PROGRESS_SUMMARIES", value: customDisableValue))
    }
    CLIEnvironmentOverrides.save(variables, defaults: suite.defaults)
  }

  func configuration(mode: CLICommandMode) -> CLICommandConfiguration {
    CLICommandConfiguration(command: executable.lastPathComponent, additionalPaths: [directory.path], mode: mode)
  }

  func read(_ name: String) throws -> String {
    try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
  }

  func runShell(_ command: String, environment: [String: String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  func cleanUp() {
    suite.cleanUp()
    try? FileManager.default.removeItem(at: directory)
  }
}
