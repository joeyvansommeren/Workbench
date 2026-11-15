//
//  SprintPeopleStrip.swift
//  AgentHub
//
//  The people filter as a row of avatar buttons in the Sprint list head.
//  A fixed number of avatars (`visibleLimit`, chosen by the head's
//  `ViewThatFits`), the rest in a "+n" menu. Hover and press change colour
//  only; the selected person gets an accent ring.
//

import SwiftUI

struct SprintPeopleStrip: View {
  let people: [SprintPerson]
  let selected: SprintPerson.Kind?
  let visibleLimit: Int
  let onToggle: (SprintPerson.Kind) -> Void

  var body: some View {
    let split = SprintPeopleFilter.split(people, visibleLimit: visibleLimit)
    HStack(spacing: DesignTokens.Spacing.xxs) {
      ForEach(split.visible) { person in
        SprintPersonButton(person: person, isSelected: person.kind == selected) {
          onToggle(person.kind)
        }
      }
      if !split.overflow.isEmpty {
        SprintPeopleOverflowMenu(
          people: split.overflow,
          selected: selected,
          showsCount: !split.visible.isEmpty,
          onToggle: onToggle)
      }
    }
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("People")
    .accessibilityIdentifier("sprint.people")
  }
}

// MARK: - Avatar button

private struct SprintPersonButton: View {
  let person: SprintPerson
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      SprintPersonAvatar(person: person)
    }
    .buttonStyle(SprintAvatarButtonStyle(isSelected: isSelected))
    .focusEffectDisabled()
    .help("\(person.accessibilityName) · \(person.ticketCountText)")
    .accessibilityLabel(person.accessibilityName)
    .accessibilityValue(person.ticketCountText)
    .accessibilityHint(isSelected ? "Shows everyone's tickets" : "Shows only these tickets")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// Initials, or a person glyph for Unassigned, on a 22 pt circle.
private struct SprintPersonAvatar: View {
  let person: SprintPerson

  var body: some View {
    Group {
      if let initials = person.initials {
        Text(initials)
          // Prototype `.avatar`: Inter 600 9px, letter-spacing 0.02em.
          .font(WorkbenchTypography.uiFont(size: 9, weight: .semibold))
          .tracking(0.02 * 9)
      } else {
        Image(systemName: "person.fill.questionmark")
          .font(.system(size: 10))
      }
    }
    .frame(width: SprintAvatarMetrics.avatar, height: SprintAvatarMetrics.avatar)
  }
}

enum SprintAvatarMetrics {
  /// The avatar circle inside a 28 pt control.
  static let avatar: CGFloat = 22
  static let ring: CGFloat = 1.5
}

/// Colour-only feedback, no scale (`scripts/check-motion.sh`): selected =
/// accent tint, accent text and an accent ring; pressed > hover > rest
/// otherwise. A body view, so it can read hover, focus and `isEnabled`.
private struct SprintAvatarButtonStyle: ButtonStyle {
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    SprintAvatarBody(label: configuration.label, isPressed: configuration.isPressed, isSelected: isSelected)
  }
}

private struct SprintAvatarBody<Label: View>: View {
  let label: Label
  let isPressed: Bool
  let isSelected: Bool

  @Environment(\.isFocused) private var isFocused
  @State private var isHovered = false

  var body: some View {
    SprintAvatarChrome(isSelected: isSelected, isHovered: isHovered, isPressed: isPressed) { label }
      .wbFocusRing(isFocused, cornerRadius: DesignTokens.Size.control / 2)
      .onHover { isHovered = $0 }
  }
}

/// The circle shared by avatars and the "+n" menu label.
private struct SprintAvatarChrome<Content: View>: View {
  let isSelected: Bool
  let isHovered: Bool
  let isPressed: Bool
  @ViewBuilder let content: Content

  var body: some View {
    content
      .foregroundStyle(isSelected ? Color.wbAccentText : (isHovered ? Color.wbTextPrimary : Color.wbTextSecondary))
      .frame(width: SprintAvatarMetrics.avatar, height: SprintAvatarMetrics.avatar)
      .background(fill, in: Circle())
      .overlay {
        Circle().strokeBorder(Color.wbBorderControl, lineWidth: 0.5)
      }
      .frame(width: DesignTokens.Size.control, height: DesignTokens.Size.control)
      .overlay {
        if isSelected {
          Circle().strokeBorder(Color.wbAccent, lineWidth: SprintAvatarMetrics.ring)
        }
      }
      .contentShape(Circle())
  }

  private var fill: Color {
    if isSelected { return .wbAccentTint }
    if isPressed { return .wbSurfacePressed }
    if isHovered { return .wbSurfaceHover }
    return .wbSurfaceRaised
  }
}

// MARK: - Overflow

/// "+n": the people that do not fit, as a menu with a check on the selected
/// one. Selected style when the selected person is in here. With no avatars
/// next to it (`showsCount` false) it shows a people glyph instead.
private struct SprintPeopleOverflowMenu: View {
  let people: [SprintPerson]
  let selected: SprintPerson.Kind?
  let showsCount: Bool
  let onToggle: (SprintPerson.Kind) -> Void

  @State private var isHovered = false

  private var containsSelection: Bool {
    people.contains { $0.kind == selected }
  }

  var body: some View {
    Menu {
      ForEach(people) { person in
        Button {
          onToggle(person.kind)
        } label: {
          let title = "\(person.accessibilityName) · \(person.ticketCountText)"
          if person.kind == selected {
            Label(title, systemImage: "checkmark")
          } else {
            Text(title)
          }
        }
      }
    } label: {
      SprintAvatarChrome(isSelected: containsSelection, isHovered: isHovered, isPressed: false) {
        if showsCount {
          Text("+\(people.count)")
            .font(WorkbenchTypography.uiFont(size: 10, weight: .semibold))
            .monospacedDigit()
        } else {
          Image(systemName: "person.2")
            .font(.system(size: 10))
        }
      }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .onHover { isHovered = $0 }
    .help(showsCount ? "\(people.count) more people" : "People")
    .accessibilityLabel(showsCount ? "\(people.count) more people" : "People")
    .accessibilityValue(selectedName ?? "")
    .accessibilityIdentifier("sprint.people.more")
  }

  private var selectedName: String? {
    people.first { $0.kind == selected }.map { "\($0.accessibilityName) selected" }
  }
}
