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
              .frame(minHeight: DesignTokens.Size.controlSmall)
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
    // Without a URL the row is plain content: a button that does nothing
    // would still be offered to VoiceOver and the keyboard.
    if let url = item.detailsURL {
      Button {
        NSWorkspace.shared.open(url)
      } label: {
        content
      }
      .buttonStyle(.plain)
      .background(
        isHovered ? Color.wbSurfaceHover : .clear,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.segment)
      )
      .overlay(alignment: .bottom) { divider }
      .onHover { isHovered = $0 }
      .help("Open \(item.name) on GitHub")
      .accessibilityLabel("\(item.name), \(item.statusText)")
    } else {
      content
        .overlay(alignment: .bottom) { divider }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.statusText)")
    }
  }

  @ViewBuilder
  private var divider: some View {
    if showsDivider {
      Color.wbBorderHairline.frame(height: 1).padding(.horizontal, DesignTokens.Spacing.sm)
    }
  }

  private var content: some View {
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
}

// MARK: - Conversation

struct PullRequestConversationSection: View {
  let entries: [PullRequestDetailPresentation.ConversationEntry]
  let viewerLogin: String?

  /// Long threads show the latest entries first; this unfolds the rest.
  @State private var showsAll = false

  var body: some View {
    let visible = PullRequestDetailPresentation.visibleConversation(entries, showsAll: showsAll)
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      PullRequestSectionTitle(title: "Conversation", count: entries.count)
      if entries.isEmpty {
        Text("No comments or reviews yet.")
          .wbText(.body)
          .foregroundStyle(Color.wbTextSecondary)
      } else {
        if visible.hiddenCount > 0 {
          Button {
            showsAll = true
          } label: {
            Text("Show \(visible.hiddenCount) earlier")
              .wbText(.callout)
              .foregroundStyle(Color.wbAccentText)
              .frame(minHeight: DesignTokens.Size.controlSmall)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        ForEach(visible.entries) { entry in
          PullRequestConversationEntryView(
            entry: entry,
            isViewer: isViewer(entry.author),
            showsDivider: entry.id != visible.entries.last?.id
          )
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
  let showsDivider: Bool

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
      if showsDivider {
        Color.wbBorderHairline.frame(height: 1)
      }
    }
  }

  private var heading: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      Text(isViewer ? "You" : entry.author)
        .wbText(.bodyEmphasis)
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
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
