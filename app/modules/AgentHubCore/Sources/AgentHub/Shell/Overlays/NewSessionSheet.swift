//
//  NewSessionSheet.swift
//  AgentHub
//
//  The new shell's New session sheet (prototype `NewSessionSheet`,
//  `ProjectPicker`, `WorktreePicker`, `WorktreePopover`): agent, project,
//  worktree and prompt, then Start ⌘↩. "More options…" hands the same launch
//  view model to the legacy launcher for parallel and smart launches.
//

import SwiftUI

struct NewSessionSheet: View {
  @Bindable var model: NewSessionSheetModel
  let onCancel: () -> Void
  let onMoreOptions: () -> Void

  @FocusState private var isPromptFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
      Text("New session")
        .wbText(.title3)
        .foregroundStyle(Color.wbTextPrimary)

      Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.md, verticalSpacing: DesignTokens.Spacing.md) {
        GridRow {
          NewSessionFormLabel("Agent")
          NewSessionAgentPicker(model: model)
        }
        GridRow {
          NewSessionFormLabel("Project")
          HStack(spacing: DesignTokens.Spacing.sm) {
            NewSessionProjectPicker(model: model)
            NewSessionWorktreePicker(model: model)
          }
        }
        GridRow(alignment: .top) {
          NewSessionFormLabel("Prompt")
            .padding(.top, DesignTokens.Spacing.xsPlus)
          NewSessionPromptField(
            prompt: $model.prompt,
            placeholder: "What should \(model.agent.agentDisplayName) do?",
            isFocused: $isPromptFocused
          )
        }
      }

      if let error = model.launchViewModel.launchError {
        ErrorBanner(error) { model.launchViewModel.launchError = nil }
      }

      footer
    }
    .padding(DesignTokens.Spacing.xl)
    .frame(width: DesignTokens.Width.sheet)
    .background(Color.wbSurfaceRaised)
    .onAppear {
      model.launchViewModel.refreshCLIAvailability()
      DispatchQueue.main.async { isPromptFocused = true }
    }
  }

  private var footer: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Button("More options…", action: onMoreOptions)
        .buttonStyle(WBPlainButtonStyle())
        .help("Parallel and smart launches")
      Spacer(minLength: 0)
      Button("Cancel", action: onCancel)
        .buttonStyle(WBSecondaryButtonStyle())
        .keyboardShortcut(.cancelAction)
      Button(action: model.start) {
        HStack(spacing: DesignTokens.Spacing.xsPlus) {
          Text("Start")
          HStack(spacing: DesignTokens.Spacing.xxs) {
            StartKeyCap("⌘")
            StartKeyCap("↩")
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(WBPrimaryButtonStyle())
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!model.canStart)
      .accessibilityIdentifier("newSession.start")
    }
    .padding(.top, DesignTokens.Spacing.xs)
  }
}

// MARK: - Form pieces

/// Right-aligned form label in the 76 pt label column (`.form-label`).
private struct NewSessionFormLabel: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .wbText(.body)
      .foregroundStyle(Color.wbTextSecondary)
      .frame(width: 76, alignment: .trailing)
  }
}

/// A key cap on the accent button (`.button-primary .keycap`).
private struct StartKeyCap: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(Color.wbTextOnAccent)
      .frame(minWidth: 20, minHeight: 20)
      .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
  }
}

/// Two equal segments (`.segmented-wide`). A missing CLI disables its segment.
private struct NewSessionAgentPicker: View {
  @Bindable var model: NewSessionSheetModel

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xxs) {
      ForEach(SessionProviderKind.allCases, id: \.self) { provider in
        segment(provider)
      }
    }
    .padding(DesignTokens.Inset.control)
    .frame(height: DesignTokens.Size.control)
    .background(Color.wbSurfaceField, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Agent")
  }

  private func segment(_ provider: SessionProviderKind) -> some View {
    let isSelected = model.agent == provider
    let isAvailable = model.isAgentAvailable(provider)
    return Button {
      model.agent = provider
    } label: {
      Text(provider.agentDisplayName)
        .wbText(.body)
        .fontWeight(.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextSecondary)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.segment)
          .fill(Color.wbSurfaceSegmentSelected)
          .wbElevation(.raised, cornerRadius: DesignTokens.Radius.segment)
      }
    }
    .disabled(!isAvailable)
    .opacity(isAvailable ? 1 : 0.45)
    .help(isAvailable ? "" : provider.notInstalledHelp)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct NewSessionPromptField: View {
  @Binding var prompt: String
  let placeholder: String
  var isFocused: FocusState<Bool>.Binding

  var body: some View {
    TextEditor(text: $prompt)
      .wbText(.body)
      .foregroundStyle(Color.wbTextPrimary)
      .scrollContentBackground(.hidden)
      .focused(isFocused)
      .padding(.horizontal, DesignTokens.Spacing.smPlus - 5)
      .padding(.vertical, DesignTokens.Spacing.sm)
      .frame(minHeight: 104, maxHeight: 104)
      .background(alignment: .topLeading) {
        if prompt.isEmpty {
          Text(placeholder)
            .wbText(.body)
            .foregroundStyle(Color.wbTextPlaceholder)
            .padding(.horizontal, DesignTokens.Spacing.smPlus)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .allowsHitTesting(false)
        }
      }
      .background(Color.wbSurfaceField, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
      .accessibilityLabel("Prompt")
  }
}

// MARK: - Popup buttons

/// `.popup-button`: control surface, leading content, trailing chevron.
private struct PopupButtonLabel<Leading: View>: View {
  let title: String
  let isMonospaced: Bool
  @ViewBuilder let leading: Leading
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      leading
      Text(title)
        .wbText(isMonospaced ? .code : .body)
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
        .truncationMode(.middle)
      Image(systemName: "chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color.wbTextSecondary)
        .padding(.leading, DesignTokens.Spacing.xs)
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .frame(height: DesignTokens.Size.control)
    .background(
      isHovered ? Color.wbSurfaceControlHover : Color.wbSurfaceControl,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item)
    )
    .wbElevation(.control, cornerRadius: DesignTokens.Radius.item)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
  }
}

private struct NewSessionProjectPicker: View {
  @Bindable var model: NewSessionSheetModel
  @State private var isOpen = false

  var body: some View {
    Button { isOpen.toggle() } label: {
      PopupButtonLabel(title: model.project?.name ?? "Choose project", isMonospaced: false) {
        if let project = model.project {
          LetterTile(name: project.name, path: project.path)
        } else {
          Image(systemName: "folder").foregroundStyle(Color.wbTextSecondary)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Project, \(model.project?.name ?? "none")")
    .popover(isPresented: $isOpen, arrowEdge: .bottom) {
      OverlayMenuList {
        ForEach(model.repositories) { repository in
          OverlayMenuRow(
            title: repository.name,
            isChecked: repository.path == model.project?.path
          ) {
            LetterTile(name: repository.name, path: repository.path)
          } action: {
            model.selectProject(repository)
            isOpen = false
          }
        }
        if !model.repositories.isEmpty { OverlayMenuDivider() }
        OverlayMenuRow(title: "Other…", isChecked: false) {
          Image(systemName: "folder")
        } action: {
          isOpen = false
          model.chooseOtherProject()
        }
      }
    }
  }
}

private struct NewSessionWorktreePicker: View {
  @Bindable var model: NewSessionSheetModel
  @State private var isOpen = false

  var body: some View {
    Button { isOpen.toggle() } label: {
      PopupButtonLabel(title: title, isMonospaced: isExisting) {
        Image(systemName: icon).foregroundStyle(Color.wbTextSecondary)
      }
    }
    .buttonStyle(.plain)
    .disabled(model.project == nil)
    .accessibilityLabel("Worktree, \(title)")
    .accessibilityIdentifier("newSession.worktree")
    .popover(isPresented: $isOpen, arrowEdge: .bottom) {
      WorktreePopoverContent(model: model) { isOpen = false }
    }
  }

  private var isExisting: Bool {
    if case .existing = model.worktreeChoice { return true }
    return false
  }

  private var title: String {
    switch model.worktreeChoice {
    case .newWorktree: return "New worktree"
    case .existing(let worktree): return worktree.name
    case .none: return "No worktree"
    }
  }

  private var icon: String {
    switch model.worktreeChoice {
    case .newWorktree: return NewSessionWorktreeIcon.new
    case .existing: return NewSessionWorktreeIcon.existing
    case .none: return NewSessionWorktreeIcon.none
    }
  }
}

private enum NewSessionWorktreeIcon {
  static let new = "plus.square.dashed"
  static let existing = "arrow.triangle.branch"
  static let none = "folder"
}

/// `WorktreePopover`: search, "Start session in", New / existing / None.
private struct WorktreePopoverContent: View {
  @Bindable var model: NewSessionSheetModel
  let onClose: () -> Void

  var body: some View {
    OverlayMenuList {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 13))
          .foregroundStyle(Color.wbTextSecondary)
        TextField("Search worktrees", text: $model.worktreeSearch)
          .textFieldStyle(.plain)
          .wbText(.body)
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: 36)

      OverlayMenuLabel("Start session in")

      row("New worktree", icon: NewSessionWorktreeIcon.new, choice: .newWorktree, mono: false)
      ForEach(model.existingWorktrees) { worktree in
        row(worktree.name, icon: NewSessionWorktreeIcon.existing, choice: .existing(worktree), mono: true)
      }
      OverlayMenuDivider()
      row("No worktree", icon: NewSessionWorktreeIcon.none, choice: .none, mono: false)
    }
  }

  private func row(
    _ title: String,
    icon: String,
    choice: NewSessionWorktreeChoice,
    mono: Bool
  ) -> some View {
    OverlayMenuRow(title: title, isChecked: model.worktreeChoice == choice, isMonospaced: mono) {
      Image(systemName: icon)
    } action: {
      model.selectWorktree(choice)
      onClose()
    }
  }
}

// MARK: - Menu list pieces (`.menu`, `.menu-item`, `.menu-label`)

struct OverlayMenuList<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
    }
    .padding(DesignTokens.Inset.container)
    .frame(width: DesignTokens.Width.popover)
  }
}

struct OverlayMenuLabel: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(WorkbenchTextStyle.subheadline.font())
      .fontWeight(.medium)
      .foregroundStyle(Color.wbTextSecondary)
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .padding(.top, DesignTokens.Spacing.sm)
      .padding(.bottom, DesignTokens.Spacing.xs)
  }
}

struct OverlayMenuDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color.wbBorderHairline)
      .frame(height: 1)
      .padding(.horizontal, -DesignTokens.Inset.container)
      .padding(.vertical, DesignTokens.Inset.container)
  }
}

struct OverlayMenuRow<Leading: View>: View {
  let title: String
  let isChecked: Bool
  var isMonospaced = false
  @ViewBuilder let leading: Leading
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignTokens.Spacing.smPlus) {
        leading
          .font(.system(size: 13))
          .foregroundStyle(Color.wbTextSecondary)
          .frame(width: DesignTokens.Size.icon)
        Text(title)
          .wbText(isMonospaced ? .code : .body)
          .foregroundStyle(Color.wbTextPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        if isChecked {
          Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.wbAccentText)
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: DesignTokens.Size.row)
      .background(
        isHovered ? Color.wbSurfaceHover : Color.clear,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityAddTraits(isChecked ? .isSelected : [])
  }
}

extension SessionProviderKind {
  /// The product name shown in the new shell ("Claude Code", "Codex").
  var agentDisplayName: String {
    switch self {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    }
  }
}
