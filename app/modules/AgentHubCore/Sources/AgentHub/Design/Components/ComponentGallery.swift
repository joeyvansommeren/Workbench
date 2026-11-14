#if DEBUG
//
//  ComponentGallery.swift
//  AgentHub
//
//  A debug-only gallery showing every component in its states.
//  Appearance (light/dark) is driven by the system toggle.
//  Palette (Standard/Warm) is driven by WorkbenchThemeRegistry.setPalette.
//

import SwiftUI

/// Shows every component in its states, with a palette switch.
@MainActor
public struct ComponentGallery: View {
  @State private var palette: PalettePreference = PalettePreference.fromDefaults()

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      header

      ScrollView {
        VStack(alignment: .leading, spacing: 40) {
          statusGlyphsSection
          statusChipsSection
          buttonsSection
          segmentedSection
          controlsSection
          tilesSection
          avatarsSection
          badgesSection
          metersSection
          propertyCardSection
          statesSection
          commandBlockSection
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .wbRedrawsOnPaletteChange()
    }
    .background(Color.wbSurfaceWindow)
    .frame(minWidth: 900, minHeight: 600)
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text("Component Gallery")
        .wbText(.title2)

      Spacer()

      Picker("Palette", selection: $palette) {
        ForEach(PalettePreference.allCases) { p in
          Text(p.displayName).tag(p)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 200)
      .onChange(of: palette) { _, newValue in
        MainThreadStallMonitor.breadcrumb("gallery palette: \(newValue.rawValue)")
        WorkbenchThemeRegistry.shared.setPalette(newValue)
      }
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 12)
  }

  // MARK: - Status glyphs

  private var statusGlyphsSection: some View {
    GallerySection("Status Glyphs") {
      HStack(spacing: 24) {
        glyphColumn("Thinking", .thinking)
        glyphColumn("Running", .executingTool(name: "Bash"))
        glyphColumn("Your turn", .waitingForUser)
        glyphColumn("Approval", .awaitingApproval(tool: "Bash"))
        glyphColumn("Input", .awaitingApproval(tool: "request_user_input"))
        glyphColumn("Idle", .idle)
        glyphColumn("nil", nil)
        glyphColumn("Pending", nil, isPending: true)
      }

      Text("16 pt")
        .wbText(.subheadline)
        .foregroundStyle(Color.wbTextSecondary)

      HStack(spacing: 24) {
        StatusGlyph(status: .thinking, size: 16)
        StatusGlyph(status: .executingTool(name: "Bash"), size: 16)
        StatusGlyph(status: .waitingForUser, size: 16)
        StatusGlyph(status: .awaitingApproval(tool: "Bash"), size: 16)
        StatusGlyph(status: .idle, size: 16)
      }
    }
  }

  private func glyphColumn(_ label: String, _ status: SessionStatus?, isPending: Bool = false) -> some View {
    VStack(spacing: 8) {
      StatusGlyph(status: status, isPending: isPending)
      Text(label)
        .wbText(.subheadline)
        .foregroundStyle(Color.wbTextSecondary)
    }
  }

  // MARK: - Status chips

  private var statusChipsSection: some View {
    GallerySection("Status Chips") {
      HStack(spacing: 12) {
        StatusChip(status: .thinking)
        StatusChip(status: .executingTool(name: "Bash"))
        StatusChip(status: .waitingForUser)
        StatusChip(status: .awaitingApproval(tool: "Bash"))
        StatusChip(status: .awaitingApproval(tool: "request_user_input"))
        StatusChip(status: .idle)
      }
    }
  }

  // MARK: - Buttons

  private var buttonsSection: some View {
    GallerySection("Buttons") {
      HStack(spacing: 12) {
        Button("Primary") {}
          .buttonStyle(.wbPrimary)

        Button("Secondary") {}
          .buttonStyle(.wbSecondary)

        Button("Plain") {}
          .buttonStyle(.wbPlain)

        Button("Destructive") {}
          .buttonStyle(.wbDestructive)
      }

      // Disabled
      HStack(spacing: 12) {
        Button("Disabled") {}
          .buttonStyle(.wbPrimary)
          .disabled(true)

        Button("Disabled") {}
          .buttonStyle(.wbSecondary)
          .disabled(true)
      }

      // Icon buttons
      HStack(spacing: 12) {
        IconButton(systemImage: "sidebar.left", accessibilityLabel: "Toggle sidebar") {}
        IconButton(systemImage: "sidebar.left", isToggled: true, accessibilityLabel: "Toggle sidebar") {}
        IconButton(systemImage: "plus", isSmall: true, accessibilityLabel: "Add") {}
      }

      // Split button
      SplitButton("Review with Claude", action: {}) {
        Button("Review with Codex") {}
      }
    }
  }

  // MARK: - Segmented control

  @State private var segmentedSelection: DemoSegment = .diff

  private var segmentedSection: some View {
    GallerySection("Segmented Control") {
      WorkbenchSegmentedControl(selection: $segmentedSelection) { seg in
        switch seg {
        case .diff: return 12
        case .plan: return nil
        }
      }
    }
  }

  // MARK: - Controls

  @State private var fieldText = ""
  @State private var checkboxOn = false
  @State private var checkboxOff = true

  private var controlsSection: some View {
    GallerySection("Controls") {
      HStack(spacing: 16) {
        WorkbenchField("Search...", text: $fieldText, systemImage: "magnifyingglass")
          .frame(width: 200)

        KeyCaps(["⌘", "K"])

        WBCheckbox(isChecked: $checkboxOn, label: "Option A")
        WBCheckbox(isChecked: $checkboxOff, label: "Option B")
      }
    }
  }

  // MARK: - Tiles

  private var tilesSection: some View {
    GallerySection("Letter Tiles") {
      HStack(spacing: 12) {
        LetterTile(letter: "W", color: .violet)
        LetterTile(letter: "A", color: .teal)
        LetterTile(letter: "S", color: .orange)
      }
    }
  }

  // MARK: - Avatars

  private var avatarsSection: some View {
    GallerySection("Avatars & Person Chips") {
      HStack(spacing: 12) {
        WBAvatar(initials: "JV")
        WBAvatar(initials: "AB")
        PersonChip(initials: "JV", name: "Joey")
      }
    }
  }

  // MARK: - Badges

  @State private var filterVisible = true

  private var badgesSection: some View {
    GallerySection("Badges & Chips") {
      HStack(spacing: 12) {
        CountBadge(3)
        CountBadge(12)
        CountBadge(2, style: .accent)
        if filterVisible {
          FilterChip("bug") { filterVisible = false }
        }
        FiltersButton(activeCount: 2, onOpen: {}, onClear: {})
        FiltersButton(activeCount: 0, onOpen: {}, onClear: {})
      }
    }
  }

  // MARK: - Meters

  private var metersSection: some View {
    GallerySection("Dot Meters") {
      HStack(spacing: 24) {
        VStack(spacing: 4) {
          DotMeter(fraction: 0.34)
          Text("34%").wbText(.subheadline).foregroundStyle(Color.wbTextSecondary)
        }
        VStack(spacing: 4) {
          DotMeter(fraction: 0.67)
          Text("67%").wbText(.subheadline).foregroundStyle(Color.wbTextSecondary)
        }
        VStack(spacing: 4) {
          DotMeter(fraction: 0.85)
          Text("85%").wbText(.subheadline).foregroundStyle(Color.wbTextSecondary)
        }
        VStack(spacing: 4) {
          DotMeter(fraction: 1.0)
          Text("100%").wbText(.subheadline).foregroundStyle(Color.wbTextSecondary)
        }
      }
    }
  }

  // MARK: - Property card

  private var propertyCardSection: some View {
    GallerySection("Property Card") {
      PropertyCard {
        PropertyRow("Checks", systemImage: "checkmark.circle") {
          Text("3 passed")
            .foregroundStyle(Color.wbStatusReadyText)
            .fontWeight(.medium)
        }
        PropertyRow("Changes", systemImage: "doc.text") {
          Text("+42 -18")
            .wbText(.codeSmall)
            .monospacedDigit()
        }
        PropertyRow("Session", showsDivider: false) {
          StatusChip(status: .executingTool(name: "Bash"))
        }
      }
      .frame(width: 400)
    }
  }

  // MARK: - Empty / error states

  private var statesSection: some View {
    GallerySection("Empty & Error States") {
      HStack(spacing: 24) {
        WBEmptyState(
          systemImage: "tray",
          title: "No sessions",
          description: "Open a project to start."
        ) {
          Button("Open Project") {}
            .buttonStyle(.wbSecondary)
        }
        .frame(width: 300, height: 200)
        .background(Color.wbSurfaceContent, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.container))

        WBEmptyState(
          systemImage: "exclamationmark.triangle",
          isError: true,
          title: "Connection failed",
          description: "Could not reach the CLI."
        ) {
          Button("Retry") {}
            .buttonStyle(.wbPrimary)
        }
        .frame(width: 300, height: 200)
        .background(Color.wbSurfaceContent, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.container))
      }

      ErrorBanner("Something went wrong. Please try again.")
        .frame(width: 500)
      ErrorBanner("Couldn't refresh the sprint.", action: .init("Retry") {}, onDismiss: {})
        .frame(width: 500)
      WBLoadingState("Loading", showsTitle: true)
        .frame(width: 300, height: 120)
    }
  }

  // MARK: - Command block

  private var commandBlockSection: some View {
    GallerySection("Command Block") {
      CommandBlock("brew install --cask workbench")
        .frame(width: 400)
    }
  }
}

// MARK: - Helpers

private struct GallerySection<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .wbText(.headline)
        .foregroundStyle(Color.wbTextSecondary)

      content()
    }
  }
}

private enum DemoSegment: String, CaseIterable, CustomStringConvertible {
  case diff = "Diff"
  case plan = "Plan"

  var description: String { rawValue }
}
#endif
