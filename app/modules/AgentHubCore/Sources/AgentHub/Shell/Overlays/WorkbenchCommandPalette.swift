//
//  WorkbenchCommandPalette.swift
//  AgentHub
//
//  The new shell's command palette (prototype `CommandPalette`): a 640 pt
//  overlay with a search row and grouped results from `CommandPaletteEntries`.
//  The legacy `CommandPaletteView` is untouched and still serves the old shell.
//

import SwiftUI

struct WorkbenchCommandPalette: View {
  let sessions: [CommandPaletteSessionInput]
  let pullRequests: [CommandPalettePullRequestInput]
  let onRun: (CommandPaletteTarget) -> Void
  let onClose: () -> Void

  @State private var query = ""
  /// The highlighted row, by entry id (see `CommandPaletteEntries.activeIndex`).
  @State private var activeEntryID: String?
  @FocusState private var isSearchFocused: Bool

  private var results: CommandPaletteResults {
    CommandPaletteEntries.results(query: query, sessions: sessions, pullRequests: pullRequests)
  }

  var body: some View {
    let results = results
    let entries = results.entries
    let activeIndex = CommandPaletteEntries.activeIndex(for: activeEntryID, in: entries)
    VStack(spacing: 0) {
      searchRow
      Rectangle().fill(Color.wbBorderHairline).frame(height: 1)
      CommandPaletteList(
        results: results,
        activeIndex: activeIndex,
        query: query,
        onHover: { activeEntryID = entries[$0].id }
      ) { index in
        run(entries, at: index)
      }
    }
    .frame(width: DesignTokens.Width.palette)
    .background {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.container)
        .fill(.ultraThinMaterial)
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.container).fill(Color.wbSurfaceOverlay)
        }
    }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.container))
    .wbElevation(.overlay, cornerRadius: DesignTokens.Radius.container)
    .onChange(of: query) { _, _ in activeEntryID = nil }
    .onKeyPress(.downArrow) { move(1, from: activeIndex, in: entries) }
    .onKeyPress(.upArrow) { move(-1, from: activeIndex, in: entries) }
    .onKeyPress(.return) {
      run(entries, at: activeIndex)
      return .handled
    }
    .onKeyPress(.escape) {
      onClose()
      return .handled
    }
    .onExitCommand(perform: onClose)
    .onAppear { DispatchQueue.main.async { isSearchFocused = true } }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Command palette")
  }

  private var searchRow: some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 16))
        .foregroundStyle(Color.wbTextSecondary)
      TextField("Search sessions, pull requests and commands", text: $query)
        .textFieldStyle(.plain)
        .font(WorkbenchTextStyle.title2.font())
        .fontWeight(.regular)
        .kerning(WorkbenchTextStyle.title2.tracking)
        .foregroundStyle(Color.wbTextPrimary)
        .focused($isSearchFocused)
        .accessibilityIdentifier("palette.search")
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .frame(height: 56)
  }

  private func move(_ delta: Int, from index: Int, in entries: [CommandPaletteEntry]) -> KeyPress.Result {
    guard !entries.isEmpty else { return .handled }
    activeEntryID = entries[(index + delta + entries.count) % entries.count].id
    return .handled
  }

  private func run(_ entries: [CommandPaletteEntry], at index: Int) {
    guard entries.indices.contains(index) else { return }
    onRun(entries[index].target)
  }
}

// MARK: - List

private struct CommandPaletteList: View {
  let results: CommandPaletteResults
  let activeIndex: Int
  let query: String
  let onHover: (Int) -> Void
  let onRun: (Int) -> Void

  private var entries: [CommandPaletteEntry] { results.entries }

  var body: some View {
    if entries.isEmpty {
      Text("No results for “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
        .wbText(.body)
        .foregroundStyle(Color.wbTextSecondary)
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.xxl)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          // A plain VStack is fine: typed results are capped per group
          // (`CommandPaletteEntries.typedGroupLimit`), so the list stays short.
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
              if index == 0 || entries[index - 1].group != entry.group {
                OverlayMenuLabel(entry.group.rawValue)
              }
              CommandPaletteRow(entry: entry, isActive: index == activeIndex) { onRun(index) }
                .onContinuousHover { phase in
                  // Fires only when the pointer moves, so arrow keys under a
                  // still pointer keep their highlight.
                  if case .active = phase, index != activeIndex { onHover(index) }
                }
                .id(entry.id)
              if index == entries.count - 1 || entries[index + 1].group != entry.group,
                let more = results.moreText(for: entry.group)
              {
                Text(more)
                  .wbText(.callout)
                  .foregroundStyle(Color.wbTextTertiary)
                  .padding(.horizontal, DesignTokens.Spacing.smPlus)
                  .frame(height: 28)
              }
            }
          }
          .padding(DesignTokens.Inset.container)
        }
        .frame(maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: activeIndex) { _, newIndex in
          guard entries.indices.contains(newIndex) else { return }
          proxy.scrollTo(entries[newIndex].id)
        }
      }
    }
  }
}

private struct CommandPaletteRow: View {
  let entry: CommandPaletteEntry
  let isActive: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignTokens.Spacing.smPlus) {
        CommandPaletteLeadView(lead: entry.lead)
          // 18 pt, like the sidebar's lead column: the letter tile is 18 pt.
          .frame(width: DesignTokens.Size.tile, height: DesignTokens.Size.tile)
        // No weight change on the match, so the title does not widen per keystroke.
        Text(highlighted(entry.title, entry.titleHighlight))
          .wbText(.body)
          .foregroundStyle(Color.wbTextPrimary)
          .lineLimit(1)
          .layoutPriority(1)
        if !entry.meta.isEmpty {
          Text(highlighted(entry.meta, entry.metaHighlight))
            .wbText(.codeSmall)
            .foregroundStyle(Color.wbTextSecondary)
            .lineLimit(1)
        }
        Spacer(minLength: DesignTokens.Spacing.sm)
        trailing
      }
      .padding(.horizontal, DesignTokens.Spacing.smPlus)
      .frame(height: 36)
      .background(
        isActive ? Color.wbSurfaceSelected : Color.clear,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityText)
    .accessibilityAddTraits(isActive ? .isSelected : [])
  }

  @ViewBuilder
  private var trailing: some View {
    if let text = entry.trailingText {
      Text(text)
        .wbText(.callout)
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
        .fixedSize()
    } else if !entry.keys.isEmpty {
      KeyCaps(entry.keys)
    }
  }

  private var accessibilityText: String {
    [entry.title, entry.meta, entry.trailingText ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
  }

  /// The prototype's `<mark>`: primary ink and an accent underline.
  private func highlighted(_ text: String, _ range: Range<String.Index>?) -> AttributedString {
    var attributed = AttributedString(text)
    guard let range, let marked = Range(range, in: attributed) else { return attributed }
    attributed[marked].swiftUI.foregroundColor = Color.wbTextPrimary
    attributed[marked].swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: Color.wbAccent)
    return attributed
  }
}

private struct CommandPaletteLeadView: View {
  let lead: CommandPaletteLead

  var body: some View {
    switch lead {
    case .status(let presentation):
      StatusGlyph(presentation: presentation)
    case .tile(let name, let colorKey):
      LetterTile(letter: name.first ?? "?", color: RepositoryTileColor.forPath(colorKey))
    case .symbol(let name):
      Image(systemName: name)
        .font(.system(size: 13))
        .foregroundStyle(Color.wbTextSecondary)
    case .pullRequestGlyph:
      PullRequestGlyph()
        .foregroundStyle(Color.wbTextSecondary)
    }
  }
}
