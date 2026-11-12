import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
public protocol NodeProcessGuardControlling {
  func start()
}

@MainActor
@Observable
public final class NodeProcessGuardController: NodeProcessGuardControlling {
  public static let shared = NodeProcessGuardController()
  var latestNotice: String?
  private var process: Process?
  private var output = Data()
  private var lastNotice = Date.distantPast
  private let executable: () -> String?
  private let notice: (String) -> Void

  init(executable: @escaping () -> String? = { AgentHubCLILocator.bundledCLIPath() },
    notice: @escaping (String) -> Void = NodeProcessGuardController.showNotice) {
    self.executable = executable
    self.notice = notice
  }

  public func start() {
    guard process == nil else { return }
    guard let executable = executable() else {
      notice("The process guard is missing. Restart with a complete AgentHub installation before starting sessions.")
      return
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = ["process-guard", "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
    let pipe = Pipe()
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = pipe
    child.standardError = FileHandle.nullDevice
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      Task { @MainActor in self?.receive(data) }
    }
    child.terminationHandler = { [weak self] _ in
      Task { @MainActor in
        self?.notice("The process guard stopped. Restart AgentHub to restore Node process limits.")
      }
    }
    do {
      try child.run()
      process = child
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      notice("The process guard could not start: \(error.localizedDescription)")
    }
  }

  func receive(_ data: Data, now: Date = Date()) {
    output.append(data)
    while let newline = output.firstIndex(of: 10) {
      let message = String(decoding: output[..<newline], as: UTF8.self)
      output.removeSubrange(...newline)
      guard message != "ready", !message.isEmpty else { continue }
      AppLogger.performance.error("\(message, privacy: .public)")
      // Update one inline notice; respect dismissal instead of interrupting work.
      if latestNotice != nil || now.timeIntervalSince(lastNotice) >= 600 {
        lastNotice = now
        latestNotice = message
      }
    }
  }

  func dismissNotice(now: Date = Date()) {
    latestNotice = nil
    lastNotice = now
  }

  private static func showNotice(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "AgentHub process protection"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    if let window = NSApp.keyWindow {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }
}

struct NodeProcessGuardNotice: View {
  private let controller = NodeProcessGuardController.shared

  var body: some View {
    if let message = controller.latestNotice {
      HStack(spacing: DesignTokens.Spacing.md) {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        Text(message).font(.secondaryDefault).lineLimit(2).help(message)
        Spacer(minLength: 0)
        Button { controller.dismissNotice() } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .help("Dismiss process protection notice")
        .accessibilityLabel("Dismiss process protection notice")
      }
      .padding(DesignTokens.Spacing.md)
      .background(Color.surfaceElevated)
    }
  }
}
