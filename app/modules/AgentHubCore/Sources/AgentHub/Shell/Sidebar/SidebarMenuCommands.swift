import SwiftUI

/// A menu command shared by the visual menu and accessibility actions.
struct SidebarMenuCommand {
  let id: String
  let title: String
  let systemImage: String
  var role: ButtonRole? = nil
  var isAvailable: () -> Bool = { true }
  let action: () -> Void

}

@MainActor
func performSidebarMenuCommand(id: String, entries: [SidebarMenuEntry], isVisible: Bool) -> Bool {
  guard isVisible else { return false }
  for entry in entries {
    guard case .command(let command) = entry, command.id == id else { continue }
    guard command.isAvailable() else { return false }
    command.action()
    return true
  }
  return false
}

enum SidebarMenuEntry {
  case command(SidebarMenuCommand)
  case separator
}

struct SidebarMenuCommands: View {
  let entries: [SidebarMenuEntry]

  var body: some View {
    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
      switch entry {
      case .separator:
        Divider()
      case .command(let command):
        Button(role: command.role, action: command.action) {
          Label(command.title, systemImage: command.systemImage)
        }
      }
    }
  }
}

@MainActor
func sessionMenuEntries(
  node: SessionNode,
  actions: any SidebarTreeActionHandling,
  onShowResult: @escaping () -> Void,
  canShowResult: @escaping () -> Bool = { true }
) -> [SidebarMenuEntry] {
  var entries: [SidebarMenuEntry] = [
    .command(
      SidebarMenuCommand(id: "open", title: "Open", systemImage: "arrow.right.circle") {
        actions.open(node)
      })
  ]
  if !node.isPending {
    entries.append(
      .command(
        SidebarMenuCommand(
          id: "reviewResult", title: "Review result", systemImage: "doc.text.magnifyingglass",
          isAvailable: canShowResult, action: onShowResult)))
    entries.append(
      .command(
        SidebarMenuCommand(id: "copySessionID", title: "Copy Session ID", systemImage: "doc.on.doc")
        {
          actions.copySessionID(node)
        }))
    entries.append(
      .command(
        SidebarMenuCommand(id: "viewTranscript", title: "View Transcript", systemImage: "doc.text")
        {
          actions.viewTranscript(node)
        }))
    if node.providerKind == .claude {
      entries.append(
        .command(
          SidebarMenuCommand(
            id: "openInTerminal", title: "Open in Terminal",
            systemImage: "rectangle.portrait.and.arrow.right"
          ) { actions.openInTerminal(node) }))
    }
    entries.append(
      .command(
        SidebarMenuCommand(id: "fork", title: "Fork…", systemImage: "arrow.triangle.branch") {
          actions.fork(node)
        }))
  }
  entries.append(.separator)
  entries.append(
    .command(
      SidebarMenuCommand(
        id: node.isPending ? "cancelLaunch" : "archive",
        title: node.isPending ? "Cancel Launch" : "Archive",
        systemImage: node.isPending ? "xmark" : "archivebox"
      ) { actions.archive(node) }))
  return entries
}

@MainActor
func repositoryMenuEntries(
  model: RepoHeaderRowModel, sessions: [SessionNode], actions: any SidebarTreeActionHandling
) -> [SidebarMenuEntry] {
  var entries: [SidebarMenuEntry] = [
    .command(
      SidebarMenuCommand(id: "newSession", title: "New Session", systemImage: "plus") {
        actions.startSession(at: model.path)
      }),
    .command(
      SidebarMenuCommand(
        id: "newWorktree", title: "New Worktree…", systemImage: "arrow.triangle.branch"
      ) {
        actions.createWorktree(repositoryPath: model.path)
      }),
    .command(
      SidebarMenuCommand(
        id: "newWorkspace", title: "New Workspace", systemImage: "rectangle.3.group"
      ) {
        actions.createWorkspace(projectPath: model.path)
      }),
    .command(
      SidebarMenuCommand(id: "projectDetails", title: "Project Details", systemImage: "info.circle")
      {
        actions.showProjectDetails(path: model.path, name: model.name)
      }),
    .separator,
    .command(
      SidebarMenuCommand(id: "openInFinder", title: "Open in Finder", systemImage: "folder") {
        actions.openInFinder(path: model.path)
      }),
    .command(
      SidebarMenuCommand(id: "github", title: "GitHub", systemImage: "link") {
        actions.showGitHub(path: model.path)
      }),
    .separator,
  ]
  if !sessions.isEmpty {
    entries.append(
      .command(
        SidebarMenuCommand(
          id: "archiveSessions", title: "Archive Sessions", systemImage: "archivebox"
        ) {
          actions.archiveSessions(sessions, groupName: model.name)
        }))
  }
  entries.append(
    .command(
      SidebarMenuCommand(id: "removeRepository", title: "Remove…", systemImage: "xmark") {
        actions.requestRemoveRepository(
          path: model.path, name: model.name, sessionCount: sessions.count)
      }))
  return entries
}

@MainActor
func branchMenuEntries(
  model: BranchRowModel, sessions: [SessionNode], actions: any SidebarTreeActionHandling
) -> [SidebarMenuEntry] {
  var entries: [SidebarMenuEntry] = [
    .command(
      SidebarMenuCommand(
        id: "newSessionOnBranch", title: "New Session on This Branch", systemImage: "plus"
      ) {
        actions.startSession(onBranch: model)
      })
  ]
  if let decoration = model.decoration {
    entries.append(.separator)
    if let provider = decoration.reviewProvider {
      entries.append(
        .command(
          SidebarMenuCommand(
            id: "startReview|\(provider.rawValue)", title: "Start Review with \(provider.rawValue)",
            systemImage: "checkmark.bubble"
          ) { actions.startReview(decoration) }))
    }
    if decoration.canCompare {
      entries.append(
        .command(
          SidebarMenuCommand(
            id: "compare", title: "Compare Implementation and Review",
            systemImage: "rectangle.split.2x1"
          ) { actions.compare(decoration) }))
    }
    if decoration.pullRequest != nil {
      entries.append(
        .command(
          SidebarMenuCommand(
            id: "openPullRequest", title: "Open Pull Request", systemImage: "arrow.up.right.square"
          ) {
            actions.openPullRequest(decoration)
          }))
    }
    if decoration.ticketKey != nil {
      entries.append(
        .command(
          SidebarMenuCommand(id: "openTicket", title: "Open Ticket", systemImage: "ticket") {
            actions.openTicket(decoration)
          }))
    }
    if decoration.archivableWorkflowID != nil {
      entries.append(
        .command(
          SidebarMenuCommand(
            id: "archiveWorkflow", title: "Archive Workflow", systemImage: "archivebox"
          ) {
            actions.archiveWorkflow(decoration)
          }))
    }
  }
  entries.append(.separator)
  if let worktreePath = model.worktreePath {
    entries.append(
      .command(
        SidebarMenuCommand(id: "openInFinder", title: "Open in Finder", systemImage: "folder") {
          actions.openInFinder(path: worktreePath)
        }))
  }
  if !sessions.isEmpty {
    entries.append(
      .command(
        SidebarMenuCommand(
          id: "archiveSessions", title: "Archive Sessions", systemImage: "archivebox"
        ) {
          actions.archiveSessions(sessions, groupName: model.name)
        }))
  }
  if model.isWorktree {
    entries.append(
      .command(
        SidebarMenuCommand(
          id: "removeWorktree", title: "Remove from Workbench…", systemImage: "xmark"
        ) {
          actions.requestRemoveWorktree(model, sessions: sessions)
        }))
    entries.append(
      .command(
        SidebarMenuCommand(
          id: "deleteWorktree", title: "Delete Worktree…", systemImage: "trash", role: .destructive
        ) {
          actions.requestDeleteWorktree(model, sessions: sessions)
        }))
  }
  return entries
}
