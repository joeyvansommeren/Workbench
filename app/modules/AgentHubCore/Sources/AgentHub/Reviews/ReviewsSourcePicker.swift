import AgentHubGitHub
import SwiftUI

struct ReviewsSourcePicker: View {
  @Bindable var viewModel: GitHubReviewsViewModel

  var body: some View {
    Menu {
      Button("All selected sources") { viewModel.selectOwner(id: nil) }
      Divider()
      ForEach(viewModel.sourceOwners) { owner in
        Button {
          viewModel.selectOwner(id: owner.id)
        } label: {
          Text(
            owner.isPersonal
              ? "Personal (\(owner.login))"
              : "\(viewModel.displayLabel(for: owner)) (\(owner.login))")
        }
      }
    } label: {
      Label(viewModel.sourceLabel, systemImage: "folder")
        .lineLimit(1)
    }
    .disabled(viewModel.sourceAccount == nil)
    .accessibilityLabel("Repository source")
    .accessibilityValue(viewModel.sourceLabel)
    .accessibilityIdentifier("reviews.source")
    .help("Repository ownership. Mine filters by pull request author within this source.")
  }
}
