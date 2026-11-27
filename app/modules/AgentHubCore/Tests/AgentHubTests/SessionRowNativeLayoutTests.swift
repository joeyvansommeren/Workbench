import AgentHubGitDiff
import AppKit
import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Session row native layout", .serialized)
struct SessionRowNativeLayoutTests {
  // Render the actual production label and attention controls. The outer
  // SessionTreeRow wrapper is intentionally not constructed: its provider would
  // request notification permission. These images do not prove wrapper routing,
  // keyboard, hover, context-menu or VoiceOver behavior.
  @Test("Capture normal and realistic stress data on the native sidebar surface")
  func renderNativeRows() async throws {
    let fixture = SessionRowNativeFixture()
    let cases: [(CGFloat, Bool)] = [(288, false), (240, true), (288, true), (400, true)]
    for (width, worst) in cases {
      for scheme in [ColorScheme.light, .dark] {
        let rows = models(worst: worst)
        let capture = fixture.host(rows: rows, width: width, scheme: scheme)
        defer { capture.close() }
        try await capture.waitForRows(rows.count)
        let rowWidth = width - 2 * DesignTokens.Inset.sidebar
        for (id, bounds) in capture.geometry.frames {
          #expect(bounds.width <= rowWidth + 0.5, "Row \(id) exceeds its real sidebar inset")
          #expect(bounds.height >= DesignTokens.Size.row)
          #expect(bounds.minX >= DesignTokens.Inset.sidebar - 0.5)
          #expect(bounds.maxX <= width - DesignTokens.Inset.sidebar + 0.5)
        }
        let frames = rows.compactMap { capture.geometry.frames[$0.id] }
        for pair in zip(frames, frames.dropFirst()) {
          #expect(pair.0.maxY <= pair.1.minY + 0.5, "Native rows must not overlap")
        }
        let mode = worst ? "worst" : "normal"
        let appearance = scheme == .light ? "light" : "dark"
        try capture.save(name: "workbench-session-row-\(Int(width))-\(appearance)-\(mode)")
        let secondary = try #require(capture.geometry.frames[rows[0].id])
        let plain = try #require(capture.geometry.frames[rows[4].id])
        #expect(
          secondary.height > plain.height, "Secondary context must grow the actual native row")
        print(
          "SESSION_ROW_RENDER sidebar=\(width) row=\(rowWidth) mode=\(mode) appearance=\(appearance) frames=\(frames)"
        )
        print(
          "SESSION_ROW_AX directChildren=\(capture.host.accessibilityChildren()?.count ?? 0); no control-press or VoiceOver claim"
        )
      }
    }
  }

  private func models(worst: Bool) -> [SessionRowModel] {
    let title =
      worst
      ? "👩🏽‍💻 Preserve Wiśniewska-Kowalczyk’s selected workspace — 界面の確認 and navigation after reopening"
      : "Preserve selected workspace"
    let values:
      [(String, SessionProviderKind, SessionStatus?, String?, LocalDiffSummary?, String?, Bool)] = [
        (
          title, .codex, .responseReady, "Implementer",
          LocalDiffSummary(
            fileCount: worst ? 1_284 : 3, additions: worst ? 123_456 : 128,
            deletions: worst ? 98_765 : 12),
          worst ? "Review draft #12345" : "Review PR #42", true
        ),
        (
          worst
            ? "BenachrichtigungseinstellungenForWorkspaceNavigation" : "Review keyboard navigation",
          .claude, .awaitingApproval(tool: "AskUserQuestion"), "Reviewer",
          LocalDiffSummary(fileCount: 1, additions: 1, deletions: 0), nil, true
        ),
        (
          worst ? "Đặng Thị Ngọc Hân — restore the workspace safely" : "Restore workspace",
          .claude, .awaitingApproval(tool: "Bash"), nil, nil, nil, false
        ),
        (
          worst ? "王秀英 — rename-only files retain truthful zero counts" : "Rename files",
          .codex, .idle, nil, LocalDiffSummary(fileCount: 1, additions: 0, deletions: 0), nil, false
        ),
        (worst ? "J" : "Untitled session", .codex, nil, nil, nil, nil, false),
        (
          worst ? "Literal <b>settings</b> & **review**" : "No worktree changes", .claude,
          .idle, nil, .empty, nil, false
        ),
      ]
    return values.enumerated().map { index, value in
      let (title, provider, status, role, diff, action, unread) = value
      let id = "native-row-\(index)"
      let session = CLISession(
        id: id, projectPath: "/native-row-fixture/not-a-repository",
        branchName: index == 4 ? nil : "codex/workspace-navigation",
        lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000), slug: index == 4 ? nil : title)
      let node = SessionNode(
        id: "\(provider.rawValue):\(id)", session: session,
        providerKind: provider, isPending: false, status: status,
        pendingToolName: index == 2 ? "Bash" : nil)
      var turn = SessionTurnProgress()
      if status == .responseReady {
        turn.complete(at: session.lastActivityAt, hasResponse: true)
      }
      let progress = status.map {
        SessionProgressPresentation(
          state: .init(status: $0, turnProgress: turn), projectPath: session.projectPath)
      }
      return SessionRowModel(
        node: node, title: title, roleLabel: role,
        isFirstInBranch: index == 0, isLastInBranch: index == values.count - 1,
        showProvider: true, diff: diff, action: action, progress: progress, isUnread: unread)
    }
  }
}

@MainActor
private final class SessionRowNativeFixture {
  func host(rows: [SessionRowModel], width: CGFloat, scheme: ColorScheme) -> SessionRowNativeCapture
  {
    let geometry = SessionRowNativeGeometry()
    let view = ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          HStack(spacing: 0) {
            SessionTreeRowLabel(model: row)
            if row.node.showsApprovePill {
              AttentionPill(
                title: "Review", help: "Open the session to review this request",
                accessibilityLabel: "Review request", action: {}
              )
              .padding(.leading, DesignTokens.Spacing.xs)
            } else if row.node.showsAnswerPill {
              AttentionPill(
                title: "Answer", help: "Open the session to answer",
                accessibilityLabel: "Answer \(row.title)", action: {}
              )
              .padding(.leading, DesignTokens.Spacing.xs)
            }
          }
          .padding(.trailing, DesignTokens.Spacing.xs)
          .frame(minHeight: DesignTokens.Size.row)
          .background {
            if index == 0 {
              RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                .fill(Color.wbSurfaceRaised)
            }
          }
          .background {
            GeometryReader { proxy in
              Color.clear.preference(
                key: SessionRowNativeFrames.self,
                value: [row.id: proxy.frame(in: .named("native-rows"))])
            }
          }
        }
      }
      .padding(.horizontal, DesignTokens.Inset.sidebar)
      .padding(.vertical, DesignTokens.Spacing.sm)
    }
    .coordinateSpace(name: "native-rows")
    .onPreferenceChange(SessionRowNativeFrames.self) { geometry.frames = $0 }
    .environment(\.colorScheme, scheme)
    .background(Color.wbSurfaceSidebar)
    return SessionRowNativeCapture(
      view: AnyView(view), width: width, scheme: scheme, geometry: geometry)
  }
}

@MainActor
private final class SessionRowNativeGeometry {
  var frames: [String: CGRect] = [:]
}
private struct SessionRowNativeFrames: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

@MainActor
private final class SessionRowNativeCapture {
  let host: NSHostingView<AnyView>
  let window: BackgroundTestWindow
  let geometry: SessionRowNativeGeometry

  init(view: AnyView, width: CGFloat, scheme: ColorScheme, geometry: SessionRowNativeGeometry) {
    self.geometry = geometry
    window = BackgroundTestWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 360),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
    host = NSHostingView(rootView: view)
    window.contentView = host
    host.frame = CGRect(x: 0, y: 0, width: width, height: 360)
    window.presentForTesting()
  }

  func waitForRows(_ count: Int) async throws {
    let deadline = Date().addingTimeInterval(3)
    repeat {
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      if geometry.frames.count == count,
        geometry.frames.values.allSatisfy({ $0.width > 0 && $0.height >= DesignTokens.Size.row })
      {
        return
      }
      await Task.yield()
    } while Date() < deadline
    throw NativeRowsDidNotLayOut()
  }

  func save(name: String) throws {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/private/tmp/\(name).png"))
  }

  func close() {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }
  private struct NativeRowsDidNotLayOut: Error {}
}
