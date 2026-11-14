//
//  SessionSidePanel.swift
//  AgentHub
//
//  The session side panel (`.side-panel` in the prototype): Diff | Plan plus
//  the extras that apply (`SidePanelSegments`), the diffstat, the panel body
//  (`SidePanelContentView`, shared with the legacy panel) and
//  "Commit N files".
//

import AgentHubGitDiff
import SwiftUI

struct SessionSidePanel<PanelBody: View>: View {
  @Binding var segment: SidePanelSegment
  let availability: SidePanelAvailability
  let diffSummary: LocalDiffSummary?
  let onCommit: (() -> Void)?
  @ViewBuilder let panelBody: () -> PanelBody

  var body: some View {
    VStack(spacing: 0) {
      head
      panelBody()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
      if segment == .diff, let diffSummary, diffSummary.fileCount > 0, let onCommit {
        foot(fileCount: diffSummary.fileCount, onCommit: onCommit)
      }
    }
    .background(Color.wbSurfaceContent)
  }

  private var head: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      SidePanelSegmentControl(selection: $segment, availability: availability)
      Spacer(minLength: 0)
      if let diffSummary, diffSummary.fileCount > 0 {
        DiffStat(additions: diffSummary.additions, deletions: diffSummary.deletions)
      }
    }
    .padding(.leading, DesignTokens.Spacing.lg)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: 52)
  }

  private func foot(fileCount: Int, onCommit: @escaping () -> Void) -> some View {
    Button(action: onCommit) {
      Text(CommitChangesAction.title(fileCount: fileCount))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(WBSecondaryButtonStyle())
    .padding(.top, DesignTokens.Spacing.md)
    .padding([.horizontal, .bottom], DesignTokens.Spacing.lg)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.wbBorderHairline).frame(height: 1)
    }
    .accessibilityHint("Asks the agent to commit the changes")
  }
}

/// `.diffstat`: +additions −deletions in mono.
struct DiffStat: View {
  let additions: Int
  let deletions: Int

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      Text("+\(additions)").foregroundStyle(Color.wbDiffAddedText)
      // U+2212, as in the pull request detail: same width as "+".
      Text("−\(deletions)").foregroundStyle(Color.wbDiffRemovedText)
    }
    .wbText(.codeSmall)
    .monospacedDigit()
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(additions) additions, \(deletions) deletions")
  }
}

/// Diff | Plan, then up to two extras inline; more extras collapse into "More".
private struct SidePanelSegmentControl: View {
  @Binding var selection: SidePanelSegment
  let availability: SidePanelAvailability

  var body: some View {
    let inline = SidePanelSegments.primary + SidePanelSegments.inlineExtras(availability)
    let menu = SidePanelSegments.menuExtras(availability)
    HStack(spacing: DesignTokens.Spacing.xxs) {
      ForEach(inline, id: \.self) { segment in
        segmentButton(segment)
      }
      if !menu.isEmpty {
        moreMenu(menu)
      }
    }
    .padding(DesignTokens.Inset.control)
    .frame(height: DesignTokens.Size.control)
    .background(Color.wbSurfaceField, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Side panel")
  }

  private func segmentButton(_ segment: SidePanelSegment) -> some View {
    let isSelected = selection == segment
    let count = SidePanelSegments.count(for: segment, availability: availability)
    return Button {
      selection = segment
    } label: {
      HStack(spacing: DesignTokens.Spacing.xsPlus) {
        SidePanelSegmentIconView(icon: SidePanelSegments.icon(for: segment))
        Text(SidePanelSegments.title(for: segment))
        if let count, count > 0 {
          Text("\(count)")
            .wbText(.subheadline)
            .monospacedDigit()
            .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextTertiary)
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.smPlus)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .wbText(.callout)
    .fontWeight(.medium)
    .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextSecondary)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.segment)
          .fill(Color.wbSurfaceSegmentSelected)
          .wbElevation(.raised, cornerRadius: DesignTokens.Radius.segment)
      }
    }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func moreMenu(_ segments: [SidePanelSegment]) -> some View {
    let selectedInMenu = segments.contains(selection)
    return Menu {
      ForEach(segments, id: \.self) { segment in
        Button {
          selection = segment
        } label: {
          let count = SidePanelSegments.count(for: segment, availability: availability)
          Label {
            Text(
              count.map { "\(SidePanelSegments.title(for: segment)) (\($0))" }
                ?? SidePanelSegments.title(for: segment))
          } icon: {
            SidePanelSegmentIconView(icon: SidePanelSegments.icon(for: segment), inMenu: true)
          }
        }
      }
    } label: {
      Text(selectedInMenu ? SidePanelSegments.title(for: selection) : "More")
        .wbText(.callout)
        .fontWeight(.medium)
        .foregroundStyle(selectedInMenu ? Color.wbTextPrimary : Color.wbTextSecondary)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .background {
      if selectedInMenu {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.segment)
          .fill(Color.wbSurfaceSegmentSelected)
          .wbElevation(.raised, cornerRadius: DesignTokens.Radius.segment)
      }
    }
    .accessibilityLabel("More side panels")
  }
}

/// A segment icon: an SF Symbol, or the drawn `PullRequestGlyph`.
private struct SidePanelSegmentIconView: View {
  let icon: SidePanelSegmentIcon
  /// Menus (`NSMenu`) draw images only, so the glyph goes in as a template image.
  var inMenu = false

  var body: some View {
    switch icon {
    case .system(let name):
      Image(systemName: name)
        .font(.system(size: 11))
    case .pullRequest where inMenu:
      if let image = Self.pullRequestMenuImage {
        Image(nsImage: image)
      }
    case .pullRequest:
      PullRequestGlyph(size: 12)
    }
  }

  @MainActor private static let pullRequestMenuImage: NSImage? = {
    let renderer = ImageRenderer(content: PullRequestGlyph(size: 16).foregroundStyle(Color.black))
    renderer.scale = 2
    let image = renderer.nsImage
    image?.isTemplate = true
    return image
  }()
}
