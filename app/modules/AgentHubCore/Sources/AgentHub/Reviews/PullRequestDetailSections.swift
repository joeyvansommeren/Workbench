//
//  PullRequestDetailSections.swift
//  AgentHub
//
//  The checks list and the conversation in the Reviews detail panel. Both
//  were in the legacy detail; restyled here on the P1 tokens.
//

import AppKit
import MarkdownUI
import SwiftUI

// MARK: - Checks

struct PullRequestChecksSection: View {
  let items: [PullRequestDetailPresentation.CheckItem]

  /// Long check lists fold after this many rows; failing ones sort first.
  private static let foldedCount = 6
  @State private var showsAll = false

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      PullRequestSectionTitle(title: "Checks", count: items.count)
      if items.isEmpty {
        Text("No checks reported.")
          .wbText(.body)
          .foregroundStyle(Color.wbTextSecondary)
      } else {
        VStack(spacing: 0) {
          ForEach(visibleItems) { item in
            PullRequestCheckRow(item: item, showsDivider: item.id != visibleItems.last?.id)
          }
        }
        if items.count > Self.foldedCount {
          Button {
            showsAll.toggle()
          } label: {
            Text(showsAll ? "Show fewer" : "Show all \(items.count)")
              .wbText(.callout)
              .foregroundStyle(Color.wbAccentText)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var visibleItems: [PullRequestDetailPresentation.CheckItem] {
    showsAll ? items : Array(items.prefix(Self.foldedCount))
  }
}

private struct PullRequestCheckRow: View {
  let item: PullRequestDetailPresentation.CheckItem
  let showsDivider: Bool

  @State private var isHovered = false

  var body: some View {
    Button {
      guard let url = item.detailsURL else { return }
      NSWorkspace.shared.open(url)
    } label: {
      HStack(spacing: DesignTokens.Spacing.sm) {
        if let state = item.state {
          PullRequestChecksIcon(state: state)
        } else {
          Image(systemName: "circle.dashed")
            .font(.system(size: 12))
            .foregroundStyle(Color.wbTextTertiary)
            .frame(width: 14, height: 14)
        }
        Text(item.name)
          .wbText(.body)
          .foregroundStyle(Color.wbTextPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
        if let workflow = item.workflow {
          Text(workflow)
            .wbText(.callout)
            .foregroundStyle(Color.wbTextTertiary)
            .lineLimit(1)
        }
        Spacer(minLength: DesignTokens.Spacing.sm)
        Text(item.statusText)
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
          .fixedSize()
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(minHeight: 30)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Not `.disabled` without a URL: that would dim the row like an error.
    .allowsHitTesting(item.detailsURL != nil)
    .background(
      isHovered && item.detailsURL != nil ? Color.wbSurfaceHover : .clear,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.segment)
    )
    .overlay(alignment: .bottom) {
      if showsDivider {
        Color.wbBorderHairline.frame(height: 1).padding(.horizontal, DesignTokens.Spacing.sm)
      }
    }
    .onHover { isHovered = $0 }
    .help(item.detailsURL == nil ? item.name : "Open \(item.name) on GitHub")
    .accessibilityLabel("\(item.name), \(item.statusText)")
  }
}

// MARK: - Conversation

struct PullRequestConversationSection: View {
  let entries: [PullRequestDetailPresentation.ConversationEntry]
  let viewerLogin: String?

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      PullRequestSectionTitle(title: "Conversation", count: entries.count)
      if entries.isEmpty {
        Text("No comments or reviews yet.")
          .wbText(.body)
          .foregroundStyle(Color.wbTextSecondary)
      } else {
        ForEach(entries) { entry in
          PullRequestConversationEntryView(entry: entry, isViewer: isViewer(entry.author))
        }
      }
    }
  }

  private func isViewer(_ login: String) -> Bool {
    guard let viewerLogin else { return false }
    return login.caseInsensitiveCompare(viewerLogin) == .orderedSame
  }
}

private struct PullRequestConversationEntryView: View {
  let entry: PullRequestDetailPresentation.ConversationEntry
  let isViewer: Bool

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
      WBAvatar(initials: entry.author)
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        heading
        if !entry.body.isEmpty {
          Markdown(entry.body)
            .markdownTheme(.pullRequestDescription)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(.bottom, DesignTokens.Spacing.sm)
    .overlay(alignment: .bottom) {
      Color.wbBorderHairline.frame(height: 1)
    }
  }

  private var heading: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      Text(isViewer ? "You" : entry.author)
        .wbText(.bodyEmphasis)
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
        .fixedSize()
      switch entry.kind {
      case .comment:
        EmptyView()
      case .review(let tag):
        ReviewsTagChip(tag: tag).fixedSize()
      case .codeComment(let location):
        Text(location)
          .wbText(.codeSmall)
          .foregroundStyle(Color.wbTextSecondary)
          .lineLimit(1)
          .truncationMode(.head)
          .help(location)
      }
      Spacer(minLength: DesignTokens.Spacing.sm)
      if let date = entry.date {
        Text(PullRequestRowPresentation.age(from: date, now: Date()))
          .wbText(.callout)
          .monospacedDigit()
          .foregroundStyle(Color.wbTextTertiary)
          .fixedSize()
          .help(date.formatted(date: .abbreviated, time: .shortened))
      }
    }
  }
}

// MARK: - Shared

private struct PullRequestSectionTitle: View {
  let title: String
  let count: Int

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      Text(title)
        .wbText(.headline)
        .foregroundStyle(Color.wbTextPrimary)
      if count > 0 {
        Text(verbatim: "\(count)")
          .wbText(.callout)
          .monospacedDigit()
          .foregroundStyle(Color.wbTextTertiary)
      }
    }
  }
}
