//
//  WorkbenchTypography.swift
//  AgentHub
//
//  Type scale for the new shell. Sizes and tracking live in one table
//  so a tuned set of values is a one-place change.
//
//  Inter Display is the default UI face. Geist Mono stays for code
//  and terminal text.
//

import SwiftUI

// MARK: - Font family

public enum WorkbenchTypography {

  /// Which font family the UI text uses.
  public enum Family: String, Sendable, CaseIterable, Identifiable {
    /// Inter Display — the new default for the shell.
    case interDisplay
    /// The system font (San Francisco).
    case system
    /// Geist — the legacy shell font.
    case geist

    public var id: String { rawValue }
  }

  // MARK: - PostScript names

  enum InterDisplay {
    static let regular = "InterDisplay-Regular"
    static let medium = "InterDisplay-Medium"
    static let semiBold = "InterDisplay-SemiBold"
    static let bold = "InterDisplay-Bold"
  }

  /// Inter Display at a size off the type scale, for glyph-like text inside
  /// fixed shapes (tile letters, avatar initials). Text runs use `.wbText`.
  public static func uiFont(size: CGFloat, weight: Font.Weight) -> Font {
    let name: String
    switch weight {
    case .bold, .heavy, .black: name = InterDisplay.bold
    case .semibold:             name = InterDisplay.semiBold
    case .medium:               name = InterDisplay.medium
    default:                    name = InterDisplay.regular
    }
    return .custom(name, size: size)
  }
}

// MARK: - Text style

/// Semantic text styles for the new shell. Each style defines a size,
/// weight, line height, tracking, and whether it uses the mono face.
/// The values are tuned for Inter Display and match the prototype's
/// CSS type-style block.
public enum WorkbenchTextStyle: String, CaseIterable, Sendable {
  case title2
  case title3
  case headline
  case body
  case bodyEmphasis
  case callout
  case subheadline
  case code
  case codeSmall
}

// MARK: - Style table

extension WorkbenchTextStyle {

  /// Point size.
  public var size: CGFloat {
    switch self {
    case .title2:       return 17
    case .title3:       return 15
    case .headline:     return 13
    case .body:         return 13
    case .bodyEmphasis: return 13
    case .callout:      return 12
    case .subheadline:  return 11
    case .code:         return 12
    case .codeSmall:    return 11
    }
  }

  /// Font weight.
  public var weight: Font.Weight {
    switch self {
    case .title2:       return .semibold
    case .title3:       return .semibold
    case .headline:     return .semibold
    case .body:         return .regular
    case .bodyEmphasis: return .medium
    case .callout:      return .regular
    case .subheadline:  return .regular
    case .code:         return .regular
    case .codeSmall:    return .regular
    }
  }

  /// Line height in points.
  public var lineHeight: CGFloat {
    switch self {
    case .title2:       return 22
    case .title3:       return 20
    case .headline:     return 18
    case .body:         return 18
    case .bodyEmphasis: return 18
    case .callout:      return 16
    case .subheadline:  return 14
    case .code:         return 18
    case .codeSmall:    return 14
    }
  }

  /// Tracking in em units, tuned for Inter Display.
  /// Title (15-17 px): -0.008 em
  /// Body (12-13 px):  +0.01 em
  /// Small (11 px):    +0.025 em
  /// Mono:              0
  public var trackingEm: CGFloat {
    switch self {
    case .title2, .title3:
      return -0.008
    case .headline, .body, .bodyEmphasis, .callout:
      return 0.01
    case .subheadline:
      return 0.025
    case .code, .codeSmall:
      return 0
    }
  }

  /// Whether this style uses the monospaced face.
  public var isMono: Bool {
    switch self {
    case .code, .codeSmall: return true
    default: return false
    }
  }

  /// Tracking in points for the given size.
  public var tracking: CGFloat {
    trackingEm * size
  }

  /// Extra space between lines, for Inter Display. See `lineSpacing(family:)`.
  public var lineSpacing: CGFloat {
    lineSpacing(family: .interDisplay)
  }

  /// Extra space SwiftUI adds between lines so they land on `lineHeight`.
  /// `.lineSpacing` adds to the font's own line height (ascender − descender
  /// + leading, about 1.21 × size for Inter), not to the point size, so
  /// subtract that. Never negative: a font taller than the token keeps its
  /// natural height.
  public func lineSpacing(family: WorkbenchTypography.Family) -> CGFloat {
    Self.lineSpacing(lineHeight: lineHeight, naturalLineHeight: naturalLineHeight(family: family))
  }

  /// The font's own line height in points.
  func naturalLineHeight(family: WorkbenchTypography.Family) -> CGFloat {
    let font = nsFont(family: family)
    return font.ascender - font.descender + font.leading
  }

  static func lineSpacing(lineHeight: CGFloat, naturalLineHeight: CGFloat) -> CGFloat {
    max(0, lineHeight - naturalLineHeight)
  }
}

// MARK: - Font resolution

extension WorkbenchTextStyle {

  /// Resolve a `Font` for this style in the given family.
  /// Mono styles always use Geist Mono regardless of family.
  public func font(family: WorkbenchTypography.Family = .interDisplay) -> Font {
    if isMono {
      return .geistMono(size: size, weight: weight)
    }
    switch family {
    case .interDisplay:
      return interDisplayFont()
    case .system:
      return .system(size: size, weight: weight)
    case .geist:
      return .geist(size: size, weight: weight)
    }
  }

  /// Resolve an `NSFont` for this style (for AppKit / terminal use).
  public func nsFont(family: WorkbenchTypography.Family = .interDisplay) -> NSFont {
    if isMono {
      let name: String
      switch weight {
      case .bold, .heavy, .black: name = DesignTokens.Typography.geistMonoBold
      case .semibold:             name = DesignTokens.Typography.geistMonoSemiBold
      case .medium:               name = DesignTokens.Typography.geistMonoMedium
      default:                    name = DesignTokens.Typography.geistMonoRegular
      }
      return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: nsWeight)
    }
    switch family {
    case .interDisplay:
      return interDisplayNSFont()
    case .system:
      return .systemFont(ofSize: size, weight: nsWeight)
    case .geist:
      let name: String
      switch weight {
      case .bold, .heavy, .black: name = DesignTokens.Typography.geistBold
      case .semibold:             name = DesignTokens.Typography.geistSemiBold
      case .medium:               name = DesignTokens.Typography.geistMedium
      default:                    name = DesignTokens.Typography.geistRegular
      }
      return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: nsWeight)
    }
  }

  private func interDisplayFont() -> Font {
    let name: String
    switch weight {
    case .bold, .heavy, .black: name = WorkbenchTypography.InterDisplay.bold
    case .semibold:             name = WorkbenchTypography.InterDisplay.semiBold
    case .medium:               name = WorkbenchTypography.InterDisplay.medium
    default:                    name = WorkbenchTypography.InterDisplay.regular
    }
    return .custom(name, size: size)
  }

  private func interDisplayNSFont() -> NSFont {
    let name: String
    switch weight {
    case .bold, .heavy, .black: name = WorkbenchTypography.InterDisplay.bold
    case .semibold:             name = WorkbenchTypography.InterDisplay.semiBold
    case .medium:               name = WorkbenchTypography.InterDisplay.medium
    default:                    name = WorkbenchTypography.InterDisplay.regular
    }
    return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: nsWeight)
  }

  private var nsWeight: NSFont.Weight {
    switch weight {
    case .bold:     return .bold
    case .semibold: return .semibold
    case .medium:   return .medium
    case .regular:  return .regular
    default:        return .regular
    }
  }
}

// MARK: - View modifier

/// Applies the workbench text style: font, tracking and line spacing.
public struct WorkbenchTextModifier: ViewModifier {
  let style: WorkbenchTextStyle
  let family: WorkbenchTypography.Family

  public func body(content: Content) -> some View {
    content
      .font(style.font(family: family))
      // `tracking` is letter-spacing (CSS `letter-spacing`); `kerning`
      // adjusts pair kerning instead.
      .tracking(style.tracking)
      .lineSpacing(style.lineSpacing(family: family))
  }
}

extension View {
  /// Apply a workbench text style (font, tracking, line spacing).
  public func wbText(
    _ style: WorkbenchTextStyle,
    family: WorkbenchTypography.Family = .interDisplay
  ) -> some View {
    modifier(WorkbenchTextModifier(style: style, family: family))
  }
}
