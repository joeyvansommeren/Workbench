import AgentHubGitHub
import SwiftUI

struct PullRequestReviewSheet: View {
  @Bindable var model: CreatePullRequestAction
  var observationSnapshot: GitHubPRObservationSnapshot?
  var onReviewCommit: (() -> Void)?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @AccessibilityFocusState private var statusFocused: Bool
  @State private var showsChangedFiles = true

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      Text("Review pull request")
        .wbText(.title3)
        .accessibilityAddTraits(.isHeader)
      if let progressMessage {
        ProgressView(progressMessage)
          .accessibilityIdentifier("session.pr.progress")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
          if let plan = model.plan {
            scope(plan)
            draftFields
          } else {
            status
            if case .handoff = model.phase { draftFields }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      footer
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 540, height: 500)
    .task { await model.prepare() }
    .onChange(of: model.phase) { _, phase in
      switch phase {
      case .failed, .pending, .mismatched: statusFocused = true
      default: break
      }
    }
    .interactiveDismissDisabled(model.phase == .publishing)
  }

  var progressMessage: String? {
    switch model.phase {
    case .preparing, .checking: "Checking the branch on GitHub…"
    case .publishing: "Checking the reviewed commits…"
    default: nil
    }
  }

  private func scope(_ plan: PullRequestPublicationPlan) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      repositoryScope(plan.key, source: plan.checkout.head, base: plan.baseBranch, baseOID: plan.refs.base)
      if plan.needsPush {
        LabeledContent("GitHub source", value: plan.refs.head ?? "Branch not published")
        Text("Push the reviewed source commit to the shown GitHub branch, then check again.")
      } else {
        Text("The reviewed source commit is on GitHub.")
      }
      Text("Check both branches on GitHub before creating the draft. You can copy this suggested title and description.")
      Text("GitHub reports pull request checks in the session after you create the draft.")
        .foregroundStyle(Color.wbTextSecondary)
      DisclosureGroup("Changed files · \(plan.files.count)", isExpanded: $showsChangedFiles) {
        ForEach(plan.files, id: \.self) { file in
          Text(file.debugDescription)
            .wbText(.codeSmall)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .wbText(.callout)
  }

  private var draftFields: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text("Title").wbText(.callout)
      TextField("Title", text: $model.title)
        .accessibilityIdentifier("session.pr.title")
      Text("Description").wbText(.callout)
      TextEditor(text: $model.body)
        .scrollContentBackground(.hidden)
        .padding(DesignTokens.Spacing.xs)
        .frame(minHeight: 72)
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .strokeBorder(Color.wbBorderHairline)
            .allowsHitTesting(false)
        }
        .accessibilityLabel("Pull request description")
        .accessibilityIdentifier("session.pr.body")
    }
    .disabled(model.isBusy)
  }

  @ViewBuilder private var status: some View {
    switch model.phase {
    case .preparing, .checking, .publishing, .reviewing:
      EmptyView()
    case .pending:
      Text("GitHub has not confirmed a pull request for the reviewed commits.")
        .accessibilityFocused($statusFocused)
    case .handoff(let handoff):
      let record = handoff.record
      repositoryScope(record.key, source: record.head, base: record.base, baseOID: record.baseOID)
      Text("Create the draft on GitHub when the branch and changes match your review.")
      Button("Open GitHub compare page") {
        Task {
          if let verified = await model.reopenHandoff() { openURL(verified) }
        }
      }
    case .mismatched(let request, let record):
      Text("GitHub found a pull request with different commits.")
        .accessibilityFocused($statusFocused)
      repositoryScope(record.key, source: record.head, base: record.base, baseOID: record.baseOID)
      commitLine("GitHub source", branch: request.branch, oid: request.head)
      commitLine("GitHub base", branch: request.base, oid: request.baseOID)
      Link("Inspect pull request #\(request.number)", destination: request.url)
    case .existing(let request):
      Link("Open pull request #\(request.number)", destination: request.url)
      checks(for: request)
    case .failed:
      if let error = model.error {
        Text(error)
          .accessibilityFocused($statusFocused)
      }
    case .confirmingRepository(let repository):
      repositoryConfirmation("\(repository.owner)/\(repository.repository)")
    }
  }

  @ViewBuilder private func checks(for request: GitHubPublishedPullRequest) -> some View {
    if let summary = Self.currentChecks(observationSnapshot, for: request) {
      if summary.total == 0 {
        Text("GitHub has reported no checks yet.")
          .foregroundStyle(Color.wbTextSecondary)
      } else {
        LabeledContent("GitHub checks", value: "\(summary.passed) passed, \(summary.failed) failed, \(summary.pending) pending")
      }
    }
    Link("View checks on GitHub", destination: request.url.appendingPathComponent("checks"))
  }

  static func currentChecks(_ snapshot: GitHubPRObservationSnapshot?, for request: GitHubPublishedPullRequest)
    -> GitHubCISummary?
  {
    guard let snapshot, snapshot.state == .ready, let observed = snapshot.pullRequest,
      observed.number == request.number, observed.url == request.url.absoluteString,
      observed.headRefOid == request.head
    else { return nil }
    return snapshot.ciSummary
  }

  private func repositoryScope(
    _ key: PullRequestPublicationKey, source: String, base: String, baseOID: String
  ) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      LabeledContent("Repository", value: "\(key.host)/\(key.owner)/\(key.repository)")
      commitLine("Reviewed source", branch: key.branch, oid: source)
      commitLine("Reviewed base", branch: base, oid: baseOID)
    }
    .wbText(.callout)
  }

  private func commitLine(_ name: String, branch: String, oid: String) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
      Text("\(name) · \(branch)")
      Text(oid)
        .wbText(.codeSmall)
        .textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
  }

  private func repositoryConfirmation(_ name: String) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      LabeledContent("Current GitHub repository", value: name)
      Text("Enter the owner and repository you intend to use.")
      TextField("Owner/repository", text: $model.repositoryName)
        .accessibilityIdentifier("session.pr.repository")
      if let error = model.error { Text(error) }
    }
  }

  private var showsCheckButton: Bool {
    switch model.phase {
    case .handoff, .mismatched, .pending: true
    default: false
    }
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button(model.phase == .reviewing ? "Cancel" : "Close", role: .cancel) { dismiss() }
        .disabled(model.phase == .publishing)
      if model.phase == .reviewing, model.plan?.needsPush == true {
        Button("Check GitHub") { Task { await model.check() } }
          .buttonStyle(WBPrimaryButtonStyle())
      } else if model.canPublish || model.phase == .reviewing || model.phase == .publishing {
        Button("Continue on GitHub") {
          Task {
            await model.publish()
            if case .handoff(let handoff) = model.phase { openURL(handoff.destination) }
          }
        }
        .buttonStyle(WBPrimaryButtonStyle())
        .disabled(!model.canPublish)
        .accessibilityIdentifier("session.pr.approve")
      } else if case .confirmingRepository = model.phase {
        Button("Verify repository") { Task { await model.confirmRepository() } }
          .buttonStyle(WBPrimaryButtonStyle())
          .disabled(model.repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      } else if model.requiresCommitReview, let onReviewCommit {
        Button("Review commit…") {
          onReviewCommit()
          dismiss()
        }
      } else if model.phase == .failed {
        Button("Review again") { Task { await model.check() } }
      } else if showsCheckButton {
        if model.canReviewCurrentCommits {
          Button("Review current commits") { Task { await model.reviewCurrentCommits() } }
        }
        Button("Check GitHub") { Task { await model.check() } }
      }
    }
  }
}
