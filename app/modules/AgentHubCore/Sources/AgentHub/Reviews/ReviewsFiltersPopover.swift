//
//  ReviewsFiltersPopover.swift
//  AgentHub
//
//  The Filters popover of the new shell's Reviews list: GitHub Project, saved
//  view and search, plus Stop while a refresh runs (Refresh is ⌘R in the
//  bar). The project and view used to sit in the legacy Reviews sidebar.
//

import AgentHubGitHub
import SwiftUI

struct ReviewsFiltersPopover: View {
  @Bindable var viewModel: GitHubReviewsViewModel
  let onStop: () -> Void
  @State private var repositoryInput = ""
  @State private var displayLabelInput = ""

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      sourceFields
      DisclosureGroup("GitHub Project (optional)") {
        field("Project") {
          Picker("Project", selection: projectBinding) {
            Text("Any Project or no Project").tag(String?.none)
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
        if let message = viewModel.projectErrorMessage {
          Text(message).font(.caption).foregroundStyle(.secondary)
        }
        Button("Load Projects") { Task { await viewModel.loadOptionalProjects() } }
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
    .onAppear {
      repositoryInput = viewModel.repositoryName
      displayLabelInput = selectedOwner.map { viewModel.ownerLabels[$0.id] ?? "" } ?? ""
    }
    .onChange(of: viewModel.selectedOwnerID) { _, _ in
      repositoryInput = viewModel.repositoryName
      displayLabelInput = selectedOwner.map { viewModel.ownerLabels[$0.id] ?? "" } ?? ""
    }
  }

  private var selectedOwner: GitHubReviewOwner? {
    viewModel.sourceOwners.first { $0.id == viewModel.selectedOwnerID }
  }

  @ViewBuilder
  private var sourceFields: some View {
    field("Repository source") { ReviewsSourcePicker(viewModel: viewModel) }
    if let account = viewModel.sourceAccount {
      Text("GitHub CLI: \(account.login) · \(account.host)")
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
    if viewModel.hasUnverifiedReviewSessions {
      Text("Older session links have no verified GitHub account. They stay saved and cannot receive review commands.")
        .font(.caption).foregroundStyle(.secondary)
    }
    if let owner = selectedOwner {
      Text("Repositories owned by \(owner.login)")
        .font(.caption).foregroundStyle(.secondary)
      field("Repository (optional)") {
        HStack {
          TextField("All repositories", text: $repositoryInput)
            .accessibilityLabel("Repository name")
            .onSubmit { viewModel.selectRepository(repositoryInput) }
          Button("Apply") { viewModel.selectRepository(repositoryInput) }
        }
      }
      if !owner.isPersonal {
        field("Display label (optional)") {
          HStack {
            TextField(owner.login, text: $displayLabelInput)
              .accessibilityLabel("Organisation display label")
            Button("Save") { viewModel.setOwnerLabel(displayLabelInput, for: owner.id) }
          }
        }
      }
    } else {
      if viewModel.hasUnavailableSources {
        Text("A saved source is unavailable. Remove it or choose another source.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Remove unavailable sources") { viewModel.removeUnavailableSources() }
      }
      field("Included in All selected sources") {
        if !viewModel.canEnableAnotherOwner {
          Text(viewModel.sourceLimitMessage)
            .font(.caption).foregroundStyle(.secondary)
        }
        ScrollView {
          VStack(alignment: .leading) {
            ForEach(viewModel.sourceOwners) { owner in
              Toggle(
                viewModel.displayLabel(for: owner),
                isOn: Binding(
                  get: { viewModel.enabledOwnerIDs.contains(owner.id) },
                  set: { viewModel.setOwnerEnabled(owner.id, enabled: $0) }))
              .disabled(!viewModel.canEnableAnotherOwner && !viewModel.enabledOwnerIDs.contains(owner.id))
            }
          }
        }
        .frame(maxHeight: 160)
      }
    }
    if viewModel.areOwnersTruncated {
      Text("Showing the first 200 organisations.").font(.caption).foregroundStyle(.secondary)
    }
  }

  private var footer: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if viewModel.isRefreshing {
        Button("Stop", action: onStop)
          .buttonStyle(.wbSecondary)
          .fixedSize()
      }
      if viewModel.isShowingCachedPullRequests {
        Text("Saved list · not current")
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
          .frame(minHeight: DesignTokens.Size.controlSmall)
          .contentShape(Rectangle())
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
        viewModel.selectProject(id: id)
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
