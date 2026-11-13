//
//  EmptyState.swift
//  AgentHub
//
//  Matches `.state` in the prototype.
//

import SwiftUI

/// The icon of a `WBEmptyState`: an SF Symbol (a string literal works), or a
/// drawn glyph SF Symbols lacks.
public enum WBEmptyStateIcon: Equatable, Sendable, ExpressibleByStringLiteral {
  case system(String)
  case pullRequest

  public init(stringLiteral value: String) {
    self = .system(value)
  }
}

/// A centered empty or error state with an icon, title, description
/// and optional action buttons.
public struct WBEmptyState<Actions: View>: View {
  let icon: WBEmptyStateIcon
  let isError: Bool
  let title: String
  let description: String?
  @ViewBuilder let actions: () -> Actions

  public init(
    systemImage: String,
    isError: Bool = false,
    title: String,
    description: String? = nil,
    @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
  ) {
    self.init(
      icon: .system(systemImage), isError: isError, title: title, description: description,
      actions: actions)
  }

  public init(
    icon: WBEmptyStateIcon,
    isError: Bool = false,
    title: String,
    description: String? = nil,
    @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
  ) {
    self.icon = icon
    self.isError = isError
    self.title = title
    self.description = description
    self.actions = actions
  }

  public var body: some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      // Icon
      iconView
        .foregroundStyle(isError ? Color.wbStatusErrorText : Color.wbTextSecondary)
        .frame(width: 40, height: 40)
        .background(
          isError ? Color.wbStatusErrorTint : Color.wbSurfaceField,
          in: RoundedRectangle(cornerRadius: 12)
        )
        .padding(.bottom, DesignTokens.Spacing.xs)

      // Title
      Text(title)
        .wbText(.headline)

      // Description
      if let description {
        Text(description)
          .wbText(.body)
          .foregroundStyle(Color.wbTextSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 300)
      }

      // Actions
      HStack(spacing: DesignTokens.Spacing.sm) {
        actions()
      }
      .padding(.top, DesignTokens.Spacing.xs)
    }
    .padding(DesignTokens.Spacing.xxl)
  }

  @ViewBuilder
  private var iconView: some View {
    switch icon {
    case .system(let name):
      Image(systemName: name).font(.system(size: 20))
    case .pullRequest:
      PullRequestGlyph(size: 20)
    }
  }
}
