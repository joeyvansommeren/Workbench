import SwiftUI

struct SessionProgressButton: View {
  let progress: SessionProgressPresentation
  let onAction: () -> Void
  @State private var showsDetails = false

  var body: some View {
    Button {
      showsDetails.toggle()
    } label: {
      HStack(spacing: DesignTokens.Spacing.xxs) {
        StatusChip(presentation: progress.status)
        Image(systemName: "chevron.down")
          .font(.caption2)
          .foregroundStyle(Color.wbTextSecondary)
      }
      .accessibilityHidden(true)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Session status")
    .accessibilityValue(progress.status.word)
    .accessibilityHint("Show progress and next action")
    .accessibilityIdentifier("session.progress")
    .help(progress.reason)
    .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
      details
    }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text(progress.status.word)
        .wbText(.headline)
        .foregroundStyle(Color.wbTextPrimary)
      Text(progress.reason)
        .fixedSize(horizontal: false, vertical: true)
      if let started = progress.startedAt {
        timestamp("Started", date: started)
      }
      if let updated = progress.updatedAt {
        timestamp("Last update", date: updated)
      }
      if let completed = progress.lastCompletedAt {
        timestamp("Last recorded completion", date: completed)
      }
      if let publication = progress.publication {
        Text(publication)
      }
      if let actionTitle {
        Button(actionTitle) {
          showsDetails = false
          onAction()
        }
      }
    }
    .wbText(.callout)
    .foregroundStyle(Color.wbTextSecondary)
    .padding(DesignTokens.Spacing.md)
    .frame(width: DesignTokens.Width.popover, alignment: .leading)
  }

  private func timestamp(_ title: String, date: Date) -> some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      Text(title)
      Spacer(minLength: DesignTokens.Spacing.sm)
      Text(date.formatted(date: .abbreviated, time: .shortened))
        .monospacedDigit()
    }
    .accessibilityElement(children: .combine)
  }

  private var actionTitle: String? {
    switch progress.action {
    case .answer, .permission, .notRunning: "Open Terminal"
    case .readResponse: "Open transcript"
    case .reviewChanges: "Review result"
    case .checkFailure: "Open checks"
    case .unavailable: "Refresh status"
    case .working, .starting: nil
    }
  }
}
