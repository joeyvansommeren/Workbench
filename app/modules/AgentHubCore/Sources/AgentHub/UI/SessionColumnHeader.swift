import SwiftUI

/// Header of one side-by-side column: who this is, what it is doing, and a
/// close that only removes the view. Clicking the title makes the column active.
struct SessionColumnHeader: View {
  let name: String
  let providerKind: SessionProviderKind
  let statusWord: String
  let isActive: Bool
  let onFocus: () -> Void
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Button(action: onFocus) {
        HStack(spacing: 6) {
          Circle()
            .fill(Color.brandPrimary(for: providerKind))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
          Text(name)
            .font(isActive ? .secondaryDefault.weight(.semibold) : .secondaryDefault)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(providerKind.rawValue)
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
            .fixedSize()
          Text("·")
            .font(.secondaryCaption)
            .foregroundStyle(.tertiary)
            .fixedSize()
          Text(statusWord)
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if isActive {
            Text("Active")
              .font(.secondaryCaption.weight(.semibold))
              .foregroundStyle(Color.brandPrimary(for: providerKind))
              .fixedSize()
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isActive ? "This column takes keyboard input" : "Make this column active")
      .accessibilityLabel("\(name), \(providerKind.rawValue), \(statusWord)\(isActive ? ", active" : "")")
      .accessibilityHint(isActive ? "" : "Makes this column active")
      Spacer(minLength: 4)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .help("Close this view. \(name) keeps running.")
      .accessibilityLabel("Close view of \(name), session keeps running")
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .frame(height: AgentHubLayout.subBarHeight)
    .background(isActive ? Color.brandPrimary(for: providerKind).opacity(0.08) : Color.clear)
  }
}
