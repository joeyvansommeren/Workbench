//
//  LinearBoardHeader.swift
//  AgentHub
//
//  Linear board header: team picker, cycle info, search, and assignee filter.
//

import AgentWorkflowLinear
import SwiftUI

struct LinearBoardHeader: View {
  @Bindable var viewModel: LinearViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
        LinearTeamSwitcher(viewModel: viewModel)
        Spacer()
        WorkspaceSearchField(prompt: "Search issues", text: $viewModel.searchText, width: 220)
        refreshButton
      }
      LinearAssigneeBar(viewModel: viewModel)
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.top, DesignTokens.Spacing.lg)
    .padding(.bottom, DesignTokens.Spacing.md)
  }

  private var refreshButton: some View {
    Button {
      Task { await viewModel.load() }
    } label: {
      if viewModel.loadState == .loading {
        ProgressView().controlSize(.small).frame(width: 16, height: 16)
      } else {
        Image(systemName: "arrow.clockwise")
          .frame(width: 16, height: 16)
      }
    }
    .buttonStyle(.borderless)
    .disabled(viewModel.loadState == .loading)
    .help("Refresh")
    .keyboardShortcut("r", modifiers: .command)
  }
}

// MARK: - LinearTeamSwitcher

private struct LinearTeamSwitcher: View {
  @Bindable var viewModel: LinearViewModel

  var body: some View {
    Menu {
      if viewModel.teams.count > 1 {
        ForEach(viewModel.teams) { team in
          Button {
            Task { await viewModel.selectTeam(team.id) }
          } label: {
            menuLabel(team.name, isSelected: team.id == viewModel.selectedTeamID)
          }
        }
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(title)
            .font(.secondaryLarge)
          if viewModel.teams.count > 1 {
            Image(systemName: "chevron.down")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.secondary)
          }
        }
        Text(subtitle)
          .font(.secondarySmall)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .fixedSize()
  }

  private var title: String {
    if let team = viewModel.selectedTeam {
      // The new shell's project filter is saved per team; say so here too.
      if let project = viewModel.selectedProject {
        return project.name
      }
      if let cycle = viewModel.activeCycle {
        return cycle.displayName
      }
      return "\(team.name) \u{2014} My Issues"
    }
    return "Linear"
  }

  private var subtitle: String {
    var parts: [String] = []
    if let team = viewModel.selectedTeam {
      parts.append(team.name)
    }
    if let cycle = viewModel.activeCycle {
      let style = Date.FormatStyle().day().month(.abbreviated)
      parts.append("\(cycle.startsAt.formatted(style)) \u{2013} \(cycle.endsAt.formatted(style))")
      let days = Calendar.current.dateComponents([.day], from: .now, to: cycle.endsAt).day ?? 0
      switch days {
      case ..<0: parts.append("ended")
      case 0: parts.append("ends today")
      case 1: parts.append("1 day left")
      default: parts.append("\(days) days left")
      }
    } else if viewModel.loadState == .loaded && viewModel.selectedProjectID == nil {
      parts.append("no active cycle")
    }
    let count = viewModel.issues.count
    parts.append("^[\(count) issue](inflect: true)")
    return parts.joined(separator: " \u{00B7} ")
  }

  @ViewBuilder
  private func menuLabel(_ title: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }
}

// MARK: - LinearAssigneeBar

private struct LinearAssigneeBar: View {
  @Bindable var viewModel: LinearViewModel

  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack(spacing: 6) {
      filterChip("Everyone", isSelected: viewModel.assigneeFilter == .everyone) {
        viewModel.assigneeFilter = .everyone
      }
      filterChip("Only mine", isSelected: viewModel.assigneeFilter == .me) {
        viewModel.assigneeFilter = .me
      }
    }
    .padding(.vertical, 2)
  }

  private func filterChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.secondarySmall)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
          Capsule().fill(
            isSelected ? Color.brandPrimary(from: runtimeTheme).opacity(0.18) : Color.primary.opacity(0.05))
        )
        .overlay(
          Capsule().strokeBorder(
            isSelected ? Color.brandPrimary(from: runtimeTheme).opacity(0.6) : .clear, lineWidth: 1)
        )
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}
