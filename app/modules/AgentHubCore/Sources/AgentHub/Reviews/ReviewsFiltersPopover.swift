//
//  ReviewsFiltersPopover.swift
//  AgentHub
//
//  The Filters popover of the new shell's Reviews list: GitHub Project, saved
//  view and search, plus reload. The project and view used to sit in the
//  legacy Reviews sidebar.
//

import SwiftUI

struct ReviewsFiltersPopover: View {
  @Bindable var viewModel: GitHubReviewsViewModel
  let onReload: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      field("Project") {
        Picker("Project", selection: projectBinding) {
          if viewModel.projects.isEmpty {
            Text("No projects").tag(String?.none)
          }
          ForEach(viewModel.projects) { project in
            Text(project.displayName).tag(Optional(project.id))
          }
        }
        .labelsHidden()
      }
      field("View") {
        Picker("View", selection: viewBinding) {
          if viewModel.availableViews.isEmpty {
            Text("No views").tag(String?.none)
          }
          ForEach(viewModel.availableViews) { view in
            Text(view.name).tag(Optional(view.id))
          }
        }
        .labelsHidden()
      }
      field("Search") {
        // Not focused on appear: focus-driven changes are a lead for the open
        // layout-loop crash (CLAUDE.md), so the user clicks in to type.
        WorkbenchField("Title, number, repo or author", text: $viewModel.searchText, systemImage: "magnifyingglass")
      }
      footer
    }
    .padding(DesignTokens.Spacing.md)
    .frame(width: DesignTokens.Width.popover)
  }

  private var footer: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Button(viewModel.isRefreshing ? "Stop" : "Reload", action: onReload)
        .buttonStyle(.wbSecondary)
        .fixedSize()
      if viewModel.isShowingCachedPullRequests {
        Text("Saved locally")
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
      }
      Spacer(minLength: 0)
      if let project = viewModel.selectedProject, let url = URL(string: project.url) {
        Link(destination: url) {
          HStack(spacing: DesignTokens.Spacing.xs) {
            Text("Open project")
            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
          }
          .wbText(.callout)
          .foregroundStyle(Color.wbAccentText)
        }
      }
    }
  }

  private func field<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text(title)
        .wbText(.subheadline)
        .fontWeight(.medium)
        .foregroundStyle(Color.wbTextSecondary)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var projectBinding: Binding<String?> {
    Binding(
      get: { viewModel.selectedProjectID },
      set: { id in
        guard let id else { return }
        viewModel.selectProject(id: id)
        MainThreadStallMonitor.breadcrumb("reviews project: \(id)")
      }
    )
  }

  private var viewBinding: Binding<String?> {
    Binding(
      get: { viewModel.selectedViewID },
      set: { id in
        guard let id else { return }
        viewModel.selectView(id: id)
        MainThreadStallMonitor.breadcrumb("reviews view: \(id)")
      }
    )
  }
}
