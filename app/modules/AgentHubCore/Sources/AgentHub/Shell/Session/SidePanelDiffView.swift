//
//  SidePanelDiffView.swift
//  AgentHub
//
//  The compact Diff for the new shell's side panel (prototype
//  `SessionSidePanel` + `DiffHunk`): a flat file list, then the selected
//  file's hunks at full panel width. Code clips sideways inside a horizontal
//  scroll per hunk instead of wrapping. The full `GitDiffView` stays one
//  click away ("Expand diff").
//

import AgentHubGitDiff
import SwiftUI

/// What reloads the list: the project's diff summary, plus the session's
/// activity, which catches changes the summary counts miss (staging, a
/// re-edit with the same line counts). Reloads are throttled in the model.
struct SidePanelDiffRefreshKey: Equatable {
  var summary: LocalDiffSummary?
  var lastActivity: Date?
}

struct SidePanelDiffView: View {
  /// Owned by the host (`SidePanelDiffModelCache`), so mode and selection
  /// survive the full diff and back.
  let model: SidePanelDiffModel
  let refreshKey: SidePanelDiffRefreshKey
  let onShowFullDiff: () -> Void

  @FocusState private var isListFocused: Bool
  @State private var isFileListExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      listHeader
      switch model.listState {
      case .loading:
        ProgressView("Loading changes…")
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        WBEmptyState(systemImage: "exclamationmark.triangle", isError: true, title: "Can't load the diff", description: message)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded:
        loadedContent
      }
    }
    .task(id: refreshKey) { await model.refreshThrottled() }
    .task(id: model.fileLoadKey) { await model.loadSelectedFileDiff() }
  }

  @ViewBuilder
  private var loadedContent: some View {
    if model.files.isEmpty {
      WBEmptyState(systemImage: "plusminus", title: "No changes")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      fileList
      ScrollView(.vertical) {
        SidePanelFileDiffBody(state: model.fileDiff, onShowFullDiff: onShowFullDiff)
          .padding(.bottom, DesignTokens.Spacing.lg)
      }
      .frame(minHeight: DesignTokens.Size.row * 2, maxHeight: .infinity)
    }
  }

  private var listHeader: some View {
    SidePanelDiffListHeader(
      mode: model.mode,
      onSelectMode: { mode in Task { await model.setMode(mode) } },
      onShowFullDiff: onShowFullDiff
    )
  }

  private var fileList: some View {
    let files = model.files
    let visibleCount = SidePanelFileListWindow.visibleCount(
      total: files.count,
      selectedIndex: files.firstIndex { $0.relativePath == model.selectedPath },
      isExpanded: isFileListExpanded
    )
    let rowCount = visibleCount + (visibleCount < files.count ? 1 : 0)
    let listHeight =
      CGFloat(min(rowCount, SidePanelFileListWindow.collapsedLimit))
      * DesignTokens.Size.row
    return ScrollViewReader { scrollProxy in
      ScrollView(.vertical) {
        LazyVStack(spacing: 0) {
          ForEach(files.prefix(visibleCount)) { file in
            let isSelected = file.relativePath == model.selectedPath
            SidePanelDiffFileRow(file: file, isSelected: isSelected) {
              model.select(path: file.relativePath)
              isListFocused = true
            }
            .id(file.relativePath)
            // Focus shows as a ring on the selected file; the fill stays grey.
            .wbFocusRing(isListFocused && isSelected, cornerRadius: DesignTokens.Radius.item)
          }
          if visibleCount < files.count {
            SidePanelShowAllFilesRow(count: files.count) { isFileListExpanded = true }
          }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .onGeometryChange(for: Bool.self) { geometry in
          geometry.size.height > 0
        } action: { hasLayout in
          guard hasLayout, let path = model.selectedPath else { return }
          scrollProxy.scrollTo(path, anchor: .center)
        }
      }
      .frame(maxHeight: listHeight)
      .focusable()
      .focused($isListFocused)
      .focusEffectDisabled()
      .onKeyPress(.upArrow) {
        model.moveSelection(by: -1)
        return .handled
      }
      .onKeyPress(.downArrow) {
        model.moveSelection(by: 1)
        return .handled
      }
      .onChange(of: model.selectedPath) { _, path in
        if let path { scrollProxy.scrollTo(path, anchor: .center) }
      }
      .task(id: model.selectedPath) {
        guard let path = model.selectedPath else { return }
        await Task.yield()
        scrollProxy.scrollTo(path, anchor: .center)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Changed files")
    }
  }
}

// MARK: - List header

/// The diff mode and a direct path to the full diff.
private struct SidePanelDiffListHeader: View {
  let mode: DiffMode
  let onSelectMode: (DiffMode) -> Void
  let onShowFullDiff: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Menu {
        Picker("Changes", selection: Binding(get: { mode }, set: onSelectMode)) {
          ForEach(DiffMode.allCases) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.inline)
      } label: {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Text(mode.rawValue)
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
        }
        .wbText(.callout)
        .foregroundStyle(Color.wbTextSecondary)
        .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Changes: \(mode.rawValue)")
      Spacer(minLength: 0)
      Button("Expand diff", action: onShowFullDiff)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .frame(height: DesignTokens.Size.control)
  }
}

// MARK: - File row

/// `.file-row`: file icon, mono path (folder dimmed), +n −m.
private struct SidePanelDiffFileRow: View {
  let file: GitDiffFileEntry
  let isSelected: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: "doc")
          .font(.system(size: 12))
          .foregroundStyle(Color.wbTextSecondary)
          .frame(width: DesignTokens.Size.icon)
        path
          .wbText(.codeSmall)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        DiffStat(additions: file.additions, deletions: file.deletions)
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: DesignTokens.Size.row)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.item)
          .fill(isSelected ? Color.wbSurfaceSelected : isHovered ? Color.wbSurfaceHover : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityLabel("\(file.relativePath), \(file.additions) additions, \(file.deletions) deletions")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// Folder (with its trailing slash) in secondary, name in primary.
  private var path: Text {
    let relativePath = file.relativePath
    let slash = relativePath.lastIndex(of: "/")
    let folder = slash.map { String(relativePath[...$0]) } ?? ""
    let name = slash.map { String(relativePath[relativePath.index(after: $0)...]) } ?? relativePath
    return Text(folder).foregroundStyle(Color.wbTextSecondary)
      + Text(name).foregroundStyle(Color.wbTextPrimary)
  }
}

/// Under a long file list: expands it in place.
private struct SidePanelShowAllFilesRow: View {
  let count: Int
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Color.clear.frame(width: DesignTokens.Size.icon, height: 1)
        Text("Show all \(count) files")
          .wbText(.callout)
          .monospacedDigit()
          .foregroundStyle(isHovered ? Color.wbTextPrimary : Color.wbTextSecondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: DesignTokens.Size.row)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

// MARK: - Selected file

private struct SidePanelFileDiffBody: View {
  let state: SidePanelFileDiffState
  let onShowFullDiff: () -> Void

  var body: some View {
    switch state {
    case .idle, .loading:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .padding(.top, DesignTokens.Spacing.lg)
    case .binary:
      note("Binary file")
    case .tooLarge:
      VStack(alignment: .leading, spacing: 0) {
        note("This diff is too large to show here.")
        fullDiffButton
          .padding(.horizontal, DesignTokens.Spacing.lg)
          .padding(.top, DesignTokens.Spacing.sm)
      }
    case .failed(let message):
      note(message)
    case .loaded(let diff):
      if diff.hunks.isEmpty {
        note("No content changes")
      }
      if diff.hasShortenedLines {
        note("Long lines shortened")
      }
      ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
        SidePanelDiffHunkView(hunk: hunk)
      }
      if diff.isTruncated {
        truncationFooter(diff)
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .wbText(.callout)
      .foregroundStyle(Color.wbTextSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, DesignTokens.Spacing.lg)
      .padding(.top, DesignTokens.Spacing.md)
  }

  private var fullDiffButton: some View {
    Button(action: onShowFullDiff) {
      Text("Show full diff")
        .contentShape(Rectangle())
    }
    .buttonStyle(WBSecondaryButtonStyle())
  }

  private func truncationFooter(_ diff: SidePanelRenderedDiff) -> some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Text("\(diff.renderedLineCount) of \(diff.totalLineCount) lines")
        .wbText(.callout)
        .monospacedDigit()
        .foregroundStyle(Color.wbTextSecondary)
      Spacer(minLength: 0)
      fullDiffButton
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.top, DesignTokens.Spacing.md)
  }
}

// MARK: - Hunk

/// `.hunk`: header row, then lines with one number column, a sign column and
/// the code. Tints and numbers stay put; only the code scrolls sideways.
private struct SidePanelDiffHunkView: View {
  let hunk: SidePanelDiffHunk

  private static let lineHeight: CGFloat = 18
  private static let signWidth: CGFloat = 14

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(hunk.header)
        .wbText(.codeSmall)
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .padding(.horizontal, DesignTokens.Spacing.smPlus)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wbSurfaceColumn)
        .overlay(alignment: .bottom) {
          Rectangle().fill(Color.wbBorderHairline).frame(height: 1)
        }
      lines
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.item)
        .strokeBorder(Color.wbBorderHairline, lineWidth: 1)
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.top, DesignTokens.Spacing.md)
  }

  private var lines: some View {
    let lines = hunk.lines
    return ZStack(alignment: .topLeading) {
      VStack(spacing: 0) {
        ForEach(lines.indices, id: \.self) { index in
          tint(lines[index].kind).frame(height: Self.lineHeight)
        }
      }
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(lines.indices, id: \.self) { index in
            gutter(lines[index])
          }
        }
        ScrollView(.horizontal) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
              code(lines[index])
            }
          }
          .padding(.trailing, DesignTokens.Spacing.md)
        }
      }
    }
    .wbText(.codeSmall)
  }

  /// 30 pt fits three digits (prototype); longer files widen by digit, from
  /// the data alone, never from geometry.
  private var numberWidth: CGFloat {
    let largest = hunk.lines.compactMap(\.displayLineNumber).max() ?? 0
    let digits = String(largest).count
    return 30 + CGFloat(max(0, digits - 3)) * 7
  }

  private func gutter(_ line: SidePanelDiffLine) -> some View {
    HStack(spacing: 0) {
      Text(line.displayLineNumber.map(String.init) ?? "")
        .monospacedDigit()
        .foregroundStyle(Color.wbTextTertiary)
        .frame(width: numberWidth - DesignTokens.Spacing.sm, alignment: .trailing)
        .padding(.trailing, DesignTokens.Spacing.sm)
      Text(sign(line.kind))
        .foregroundStyle(line.kind == .context ? Color.wbTextTertiary : textColor(line.kind))
        .frame(width: Self.signWidth, alignment: .leading)
    }
    .frame(height: Self.lineHeight)
    .accessibilityHidden(true)
  }

  private func code(_ line: SidePanelDiffLine) -> some View {
    // Text draws tabs unevenly; four spaces match git's default tab width.
    Text(line.text.replacingOccurrences(of: "\t", with: "    "))
      .foregroundStyle(textColor(line.kind))
      .lineLimit(1)
      .fixedSize()
      .frame(height: Self.lineHeight)
      .accessibilityLabel(accessibilityText(line))
  }

  private func sign(_ kind: SidePanelDiffLine.Kind) -> String {
    switch kind {
    case .context: ""
    case .added: "+"
    case .removed: "-"
    }
  }

  private func tint(_ kind: SidePanelDiffLine.Kind) -> Color {
    switch kind {
    case .context: .clear
    case .added: .wbDiffAddedTint
    case .removed: .wbDiffRemovedTint
    }
  }

  private func textColor(_ kind: SidePanelDiffLine.Kind) -> Color {
    switch kind {
    case .context: .wbTextPrimary
    case .added: .wbDiffAddedText
    case .removed: .wbDiffRemovedText
    }
  }

  private func accessibilityText(_ line: SidePanelDiffLine) -> String {
    let number = line.displayLineNumber.map { "Line \($0), " } ?? ""
    switch line.kind {
    case .context: return number + line.text
    case .added: return number + "added: " + line.text
    case .removed: return number + "removed: " + line.text
    }
  }
}
