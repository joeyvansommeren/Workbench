//
//  SessionActionsMenu.swift
//  AgentHub
//
//  The session header's "…" menu: the legacy card's actions popover (copy ID,
//  transcript, open in Terminal, refresh, name, fork, add files) and, below
//  them, the resource links (`ResourceLinksPanel`: links, current PR, local
//  changes, Create PR).
//

import AgentHubGitHub
import SwiftUI

struct SessionActionsMenu: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  let isPending: Bool
  let viewModel: CLISessionsViewModel
  let quickAccessViewModel: SessionGitHubQuickAccessViewModel
  let onDismiss: () -> Void
  let onViewTranscript: () -> Void
  let onRename: () -> Void
  let onAddFiles: () -> Void
  let onFork: () -> Void
  let onCreatePullRequest: () -> Void

  /// The row ↑/↓ moved to; Return runs it. Nil until an arrow key is used.
  @State private var highlightedIndex: Int?
  @FocusState private var isFocused: Bool

  private struct Item {
    let title: String
    let systemImage: String
    let action: () -> Void
  }

  /// The action rows in order. The resource links below them are their own
  /// controls and stay out of the arrow-key list.
  private var items: [Item] {
    var items: [Item] = []
    if !isPending {
      items.append(Item(title: "Copy Session ID", systemImage: "doc.on.doc") { viewModel.copySessionId(session) })
      items.append(Item(title: "View Transcript", systemImage: "doc.text", action: onViewTranscript))
      if providerKind == .claude {
        items.append(Item(title: "Open in Terminal", systemImage: "rectangle.portrait.and.arrow.right") {
          _ = viewModel.connectToSession(session)
        })
      }
      items.append(Item(title: "Refresh Terminal", systemImage: "arrow.clockwise") {
        viewModel.refreshTerminal(forKey: session.id, sessionId: session.id, projectPath: session.projectPath)
      })
      items.append(Item(title: "Name Session…", systemImage: "pencil", action: onRename))
      items.append(Item(title: "Fork…", systemImage: "arrow.triangle.branch", action: onFork))
    }
    items.append(Item(title: "Add Files…", systemImage: "plus.rectangle.on.folder", action: onAddFiles))
    return items
  }

  var body: some View {
    let items = items
    MenuSurface(width: DesignTokens.Width.popover + 60) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(items.indices, id: \.self) { index in
          // "Add Files…" is last and also the only row while pending.
          if index == items.count - 1, items.count > 1 { divider }
          row(items[index], isHighlighted: index == highlightedIndex)
        }
        if !isPending {
          ResourceLinksPanel(
            links: state?.detectedResourceLinks ?? [],
            providerKind: providerKind,
            currentPullRequest: quickAccessViewModel.currentBranchPR,
            localDiffSummary: viewModel.localDiffSummary(for: session.projectPath),
            isCreatingPullRequest: viewModel.creatingPullRequestSessionIDs.contains(session.id),
            onCreatePullRequest: {
              onDismiss()
              onCreatePullRequest()
            }
          ) {
            EmptyView()
          }
          .padding(.top, DesignTokens.Spacing.xs)
        }
      }
      // Arrow keys and Return work, like a native menu. Escape
      // closes the popover on its own.
      .focusable()
      .focused($isFocused)
      .focusEffectDisabled()
      .onKeyPress(.downArrow) { move(1, count: items.count) }
      .onKeyPress(.upArrow) { move(-1, count: items.count) }
      .onKeyPress(.return) {
        guard let highlightedIndex, items.indices.contains(highlightedIndex) else { return .ignored }
        run(items[highlightedIndex].action)
        return .handled
      }
      .onAppear { DispatchQueue.main.async { isFocused = true } }
    }
  }

  private func move(_ delta: Int, count: Int) -> KeyPress.Result {
    guard count > 0 else { return .ignored }
    let start = highlightedIndex ?? (delta > 0 ? -1 : count)
    highlightedIndex = min(max(start + delta, 0), count - 1)
    return .handled
  }

  private var state: SessionMonitorState? { viewModel.monitorStates[session.id] }

  private var divider: some View {
    Rectangle()
      .fill(Color.wbBorderHairline)
      .frame(height: 1)
      .padding(.vertical, DesignTokens.Spacing.xs)
  }

  private func row(_ item: Item, isHighlighted: Bool) -> some View {
    MenuRow(title: item.title, systemImage: item.systemImage, isHighlighted: isHighlighted) {
      run(item.action)
    }
  }

  /// Closes the popover first; sheets open after it is gone.
  private func run(_ action: @escaping () -> Void) {
    onDismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: action)
  }
}

private struct MenuRow: View {
  let title: String
  let systemImage: String
  var isHighlighted = false
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: systemImage)
          .font(.system(size: 12))
          .frame(width: 16)
          .foregroundStyle(Color.wbTextSecondary)
        Text(title)
          .wbText(.body)
          .foregroundStyle(Color.wbTextPrimary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: DesignTokens.Size.row - 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      isHovered || isHighlighted ? Color.wbSurfaceHover : Color.clear,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item)
    )
    .onHover { isHovered = $0 }
  }
}
