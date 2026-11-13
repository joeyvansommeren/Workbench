import AgentHubGitHub
import SwiftUI

struct GitHubReviewDetailView: View {
  @Bindable var viewModel: GitHubReviewsViewModel
  let request: GitHubProjectPullRequest

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("\(request.repositoryNameWithOwner) #\(request.number)")
          .font(.geist(size: 13, weight: .bold)).textSelection(.enabled)
        Spacer()
        Button {
          Task { await viewModel.loadSelectedDetail() }
        } label: { Image(systemName: "arrow.clockwise") }
        .disabled(viewModel.isLoadingDetail)
        .help("Refresh status and comments")
        .accessibilityLabel("Refresh pull request status and comments")
        Button { viewModel.selectedPullRequestID = nil } label: { Image(systemName: "xmark") }
          .help("Close pull request details")
          .accessibilityLabel("Close pull request details")
      }
      .padding()
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if viewModel.isLoadingDetail { ProgressView("Loading latest pull request…") }
          if let error = viewModel.detailError {
            Label(error, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red).textSelection(.enabled)
          }
          if let date = viewModel.detailUpdatedAt {
            Text("Last refreshed \(date.formatted(date: .omitted, time: .standard))")
              .font(.geist(size: 10)).foregroundStyle(.secondary)
          }
          if let detail = viewModel.selectedDetail {
            details(detail)
          } else if !viewModel.isLoadingDetail {
            Text("Use Refresh to load this pull request.").foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
    }
    .task(id: request.id) { await viewModel.loadSelectedDetail() }
  }

  private func details(_ detail: GitHubReviewDetail) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(detail.pullRequest.title).font(.geist(size: 17)).textSelection(.enabled)
      HStack {
        Label(detail.pullRequest.state, systemImage: detail.pullRequest.stateIcon)
        if detail.pullRequest.isDraft { Text("Draft") }
        if let decision = detail.pullRequest.reviewDecision { ReviewDecisionBadge(decision: decision) }
      }
      Text("\(detail.pullRequest.headRefName) → \(detail.pullRequest.baseRefName)")
        .font(.mono(size: 10)).textSelection(.enabled)
      if let url = URL(string: detail.pullRequest.url) {
        Link("Open on GitHub", destination: url)
      }
      if let body = detail.pullRequest.body, !body.isEmpty {
        MarkdownView(content: body, includeScrollView: false)
          .frame(maxWidth: 680, alignment: .leading)
          .textSelection(.enabled)
      }
      Divider()
      Text("Checks").font(.geist(size: 13, weight: .bold))
      if let checks = detail.pullRequest.statusCheckRollup, !checks.isEmpty {
        ForEach(checks) { check in
          HStack {
            Label(check.name, systemImage: check.statusIcon)
            Spacer()
            Text(check.statusDisplayName).foregroundStyle(.secondary)
          }
        }
      } else { Text("No checks reported").foregroundStyle(.secondary) }
      Divider()
      Text("Conversation").font(.geist(size: 13, weight: .bold))
      if (detail.pullRequest.comments ?? []).isEmpty && detail.reviews.isEmpty && detail.inlineComments.isEmpty {
        Text("No comments or reviews yet").foregroundStyle(.secondary)
      }
      ForEach(detail.pullRequest.comments ?? []) { comment in
        GitHubCommentCard(author: comment.author, createdAt: comment.createdAt, commentBody: comment.body)
      }
      ForEach(detail.reviews) { review in
        GitHubCommentCard(author: review.author, createdAt: review.submittedAt,
          commentBody: review.body, trailingHeader: AnyView(Text(review.state).font(.geist(size: 10))))
      }
      ForEach(detail.inlineComments) { comment in
        GitHubCommentCard(author: comment.author, createdAt: comment.createdAt,
          commentBody: comment.body,
          trailingHeader: AnyView(Text(comment.path ?? "Code comment").font(.geist(size: 10)).lineLimit(1)))
      }
    }
  }
}
