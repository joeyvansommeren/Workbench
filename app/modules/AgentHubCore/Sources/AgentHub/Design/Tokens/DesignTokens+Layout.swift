//
//  DesignTokens+Layout.swift
//  AgentHub
//
//  Extended spacing, radius, size, width, inset, motion and shadow tokens
//  for the new shell. Values match the CSS `:root` block in the prototype.
//

import SwiftUI

// MARK: - Spacing additions

extension DesignTokens.Spacing {
  public static let xxs: CGFloat = 2
  public static let xsPlus: CGFloat = 6
  public static let smPlus: CGFloat = 10
  public static let xxl: CGFloat = 24
  public static let xxxl: CGFloat = 32
}

// MARK: - Radius (extended)

extension DesignTokens.Radius {
  /// Content panel, sheet, popover, palette, board column, card.
  public static let container: CGFloat = 14
  /// Sidebar row, tab, list row.
  public static let row: CGFloat = 10
  /// Menu item, board card, button, field.
  public static let item: CGFloat = 8
  /// Segment inside a control, chip.
  public static let segment: CGFloat = 6
  /// Key cap, letter tile.
  public static let small: CGFloat = 5
  /// Pill shape.
  public static let full: CGFloat = 999
}

// MARK: - Inset

extension DesignTokens {
  public enum Inset {
    /// Content panel inset from the window edge.
    public static let panel: CGFloat = 8
    /// Sidebar content inset.
    public static let sidebar: CGFloat = 12
    /// Inner container inset.
    public static let container: CGFloat = 6
    /// Control padding (segment inside a segmented control).
    public static let control: CGFloat = 2
  }
}

// MARK: - Size

extension DesignTokens {
  public enum Size {
    public static let control: CGFloat = 28
    public static let controlSmall: CGFloat = 24
    public static let row: CGFloat = 30
    public static let tab: CGFloat = 32
    public static let icon: CGFloat = 16
    public static let iconSmall: CGFloat = 12
    public static let tile: CGFloat = 18
    public static let status: CGFloat = 12
  }
}

// MARK: - Width

extension DesignTokens {
  public enum Width {
    public static let sidebar: CGFloat = 288
    public static let sidePanel: CGFloat = 400
    public static let sheet: CGFloat = 560
    public static let palette: CGFloat = 640
    public static let popover: CGFloat = 300
  }
}

// MARK: - Motion

extension DesignTokens {
  public enum Motion {
    // Every spring is critically damped (damping 1.0): no bounce, anywhere.
    // Always apply through `.wbAnimation(_:)`, which returns nil under Reduce
    // Motion. Hover, press, selection, ⌘K-style keyboard toggles and
    // destination changes do not animate at all (see the motion plan).

    /// Transient notices (Jira status notice). Response 0.3 s.
    public static let standard: Animation = .spring(response: 0.3, dampingFraction: 1)
    /// About 120 ms (prototype `--duration-fast`): crossfades, small state
    /// swaps (approval phase, Approve pill, palette fade), exits, the repo
    /// chevron, "Load more" rows, drop-target highlight.
    public static let fast: Animation = .spring(response: 0.12, dampingFraction: 1)
    /// About 240 ms (prototype `--duration-medium`): panel content and
    /// approval banner entrances, the sidebar toggle.
    public static let medium: Animation = .spring(response: 0.24, dampingFraction: 1)

    /// The window crossfade when the user switches Standard | Warm or light |
    /// dark in the title row. Core Animation, not SwiftUI, so it is not a
    /// spring: 0.24 s on `themeCrossfadeTimingControlPoints`. It also runs
    /// under Reduce Motion (opacity only; it softens a brightness jump).
    public static let themeCrossfadeDuration: CFTimeInterval = 0.24
    /// `cubic-bezier(0.25, 1, 0.5, 1)`, the prototype's `--ease-standard`
    /// (ease-out). Feed to `CAMediaTimingFunction(controlPoints:)`.
    public static let themeCrossfadeTimingControlPoints: (Float, Float, Float, Float) = (0.25, 1, 0.5, 1)
  }
}

/// Resolve an animation, returning `nil` under Reduce Motion.
extension Animation {
  /// Returns the animation or `nil` when the user has enabled Reduce Motion.
  public static func wbAnimation(_ animation: Animation) -> Animation? {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      return nil
    }
    return animation
  }
}

// MARK: - Shadow

extension DesignTokens {
  /// Shadow level applied through the `.wbElevation(_:in:)` modifier.
  public enum Shadow: Sendable {
    case raised
    case panel
    case overlay
    case control
  }
}

/// Applies the workbench elevation treatment: a 0.5 pt ring plus one or two
/// blur layers, and in dark mode an inner top highlight. All in one modifier
/// so the shadow definition is a single source of truth.
///
/// Every shape is `.continuous`, like the fills it sits on, so the ring never
/// drifts off the fill edge at the corners.
public struct WorkbenchElevationModifier: ViewModifier {
  let level: DesignTokens.Shadow
  let overrideCornerRadius: CGFloat?
  @Environment(\.colorScheme) private var colorScheme

  public func body(content: Content) -> some View {
    let isDark = colorScheme == .dark
    let near = nearBlur(isDark: isDark)
    let far = farBlur(isDark: isDark)
    content
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(ringColor, lineWidth: 0.5)
          .allowsHitTesting(false)
      }
      .overlay {
        // Prototype `inset 0 0.5px 0`: a highlight on the top edge only. The
        // stroke follows the rounded corners; the mask fades it out down the
        // corner curve, so it never draws on the sides or the bottom. `.panel`
        // already has a white inner ring in dark mode, so it gets none.
        if isDark, level != .panel {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(highlightOpacity), lineWidth: 0.5)
            .mask(alignment: .top) {
              LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: max(cornerRadius, 1))
            }
            .allowsHitTesting(false)
        }
      }
      .shadow(color: near.color, radius: near.radius, x: 0, y: near.y)
      .shadow(color: far.color, radius: far.radius, x: 0, y: far.y)
  }

  private var cornerRadius: CGFloat {
    if let overrideCornerRadius { return overrideCornerRadius }
    switch level {
    case .raised: return DesignTokens.Radius.row
    case .panel: return DesignTokens.Radius.container
    case .overlay: return DesignTokens.Radius.container
    case .control: return DesignTokens.Radius.item
    }
  }

  private var ringColor: Color {
    switch (level, colorScheme) {
    case (.raised, .light):  return .black.opacity(0.07)
    case (.panel, .light):   return .black.opacity(0.08)
    case (.overlay, .light): return .black.opacity(0.10)
    case (.control, .light): return .black.opacity(0.14)
    case (.raised, .dark):   return .black.opacity(0.50)
    case (.panel, .dark):    return .white.opacity(0.06)
    case (.overlay, .dark):  return .black.opacity(0.60)
    case (.control, .dark):  return .black.opacity(0.50)
    default:                 return .clear
    }
  }

  /// One blur layer. A SwiftUI shadow radius is about half the CSS blur.
  private struct Blur {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
    static let none = Blur(color: .clear, radius: 0, y: 0)
  }

  /// The tight layer of the prototype's `--shadow-*` token.
  private func nearBlur(isDark: Bool) -> Blur {
    switch (level, isDark) {
    case (.raised, false):  return Blur(color: .black.opacity(0.06), radius: 1, y: 1)
    case (.raised, true):   return Blur(color: .black.opacity(0.35), radius: 1.5, y: 1)
    case (.panel, false):   return Blur(color: .black.opacity(0.04), radius: 1.5, y: 1)
    case (.panel, true):    return Blur(color: .black.opacity(0.30), radius: 1.5, y: 1)
    case (.overlay, false): return Blur(color: .black.opacity(0.12), radius: 15, y: 10)
    case (.overlay, true):  return Blur(color: .black.opacity(0.45), radius: 16, y: 12)
    case (.control, false): return Blur(color: .black.opacity(0.07), radius: 0.75, y: 0.75)
    case (.control, true):  return Blur(color: .black.opacity(0.30), radius: 0.75, y: 0.75)
    }
  }

  /// The wide second layer. Only raised (light) and overlay have one.
  private func farBlur(isDark: Bool) -> Blur {
    switch (level, isDark) {
    case (.raised, false):  return Blur(color: .black.opacity(0.04), radius: 3, y: 2)
    case (.overlay, false): return Blur(color: .black.opacity(0.10), radius: 35, y: 30)
    case (.overlay, true):  return Blur(color: .black.opacity(0.40), radius: 40, y: 30)
    default:                return .none
    }
  }

  private var highlightOpacity: Double {
    switch level {
    case .raised:  return 0.07
    case .panel:   return 0
    case .overlay: return 0.08
    case .control: return 0.08
    }
  }
}

extension View {
  /// Apply the workbench elevation shadow for the given level.
  public func wbElevation(_ level: DesignTokens.Shadow) -> some View {
    modifier(WorkbenchElevationModifier(level: level, overrideCornerRadius: nil))
  }

  /// Apply the workbench elevation shadow with an explicit corner radius.
  public func wbElevation(_ level: DesignTokens.Shadow, cornerRadius: CGFloat) -> some View {
    modifier(WorkbenchElevationModifier(level: level, overrideCornerRadius: cornerRadius))
  }
}

// MARK: - Opacity

extension DesignTokens {
  public enum Opacity {
    /// A disabled control. One value for every component.
    public static let disabled: Double = 0.45
  }
}

// MARK: - Focus ring and accessibility helpers

extension View {
  /// The prototype's `:focus-visible` ring: 3 pt of `wbFocusRing`, 1 pt
  /// outside the control's edge. An overlay, so it never changes layout.
  /// Drawn only while macOS keyboard navigation is on, like the system's own
  /// focus rings (`KeyboardNavigationSetting`).
  @MainActor
  public func wbFocusRing(_ isFocused: Bool, cornerRadius: CGFloat) -> some View {
    modifier(WBFocusRing(isFocused: isFocused, cornerRadius: cornerRadius))
  }

  /// Sets the accessibility label only when there is one, so an unlabelled
  /// view keeps its own label instead of reading as an empty string.
  @ViewBuilder
  public func optionalAccessibilityLabel(_ label: String?) -> some View {
    if let label {
      accessibilityLabel(label)
    } else {
      self
    }
  }

  /// Sets the accessibility identifier only when there is one. An empty
  /// identifier on every unnamed instance is noise for UI automation.
  @ViewBuilder
  public func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
    if let identifier {
      accessibilityIdentifier(identifier)
    } else {
      self
    }
  }
}

private struct WBFocusRing: ViewModifier {
  let isFocused: Bool
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    // Read here, in the body, so the view observes the setting.
    let showsRing = isFocused && KeyboardNavigationSetting.shared.isEnabled
    content.overlay {
      if showsRing {
        // A centred 3 pt stroke 2.5 pt outside the edge covers 1–4 pt outside.
        RoundedRectangle(cornerRadius: cornerRadius + 2.5, style: .continuous)
          .stroke(Color.wbFocusRing, lineWidth: 3)
          .padding(-2.5)
          .allowsHitTesting(false)
      }
    }
  }
}
