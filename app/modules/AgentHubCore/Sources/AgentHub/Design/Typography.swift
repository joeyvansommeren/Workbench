//
//  Typography.swift
//  AgentHub
//
//  Created by James Rochabrun on 3/21/26.
//

import SwiftUI

// MARK: - Typography

extension DesignTokens {

  /// Font family PostScript names for bundled fonts.
  public enum Typography {
    // Geist (secondary — labels, status, timestamps, messages)
    static let geistRegular = "Geist-Regular"
    static let geistMedium = "Geist-Medium"
    static let geistSemiBold = "Geist-SemiBold"
    static let geistBold = "Geist-Bold"

    // Geist Mono (primary mono — session IDs, slugs, paths, branches, code)
    static let geistMonoRegular = "GeistMono-Regular"
    static let geistMonoMedium = "GeistMono-Medium"
    static let geistMonoSemiBold = "GeistMono-SemiBold"
    static let geistMonoBold = "GeistMono-Bold"
  }
}

// MARK: - Semantic Font Tokens

extension Font {

  // MARK: - Primary (Geist Mono)
  // Use for: session IDs, slugs, paths, branches, code-like content

  public static let primaryLarge = Font.mono(size: 14, weight: .semibold)
  public static let primaryDefault = Font.mono(size: 12, weight: .medium)
  public static let primarySmall = Font.mono(size: 11, weight: .regular)
  public static let primaryCaption = Font.mono(size: 10, weight: .regular)

  // MARK: - Secondary (Geist)
  // Use for: labels, status, timestamps, message previews, UI text

  public static let secondaryLarge = Font.geist(size: 14, weight: .semibold)
  public static let secondaryDefault = Font.geist(size: 12, weight: .medium)
  public static let secondarySmall = Font.geist(size: 11, weight: .regular)
  public static let secondaryCaption = Font.geist(size: 10, weight: .regular)

  // MARK: - Heading (Geist bold)
  // Use for: section headers, panel titles

  public static let heading = Font.geist(size: 13, weight: .bold)
}

// MARK: - Raw Font Helpers

extension Font {

  /// Geist Mono — the app's monospaced font.
  public static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    geistMono(size: size, weight: weight)
  }

  /// Geist — secondary sans-serif font.
  public static func geist(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    let name: String
    switch weight {
    case .bold, .heavy, .black:
      name = DesignTokens.Typography.geistBold
    case .semibold:
      name = DesignTokens.Typography.geistSemiBold
    case .medium:
      name = DesignTokens.Typography.geistMedium
    default:
      name = DesignTokens.Typography.geistRegular
    }
    return .custom(name, size: size)
  }

  /// Geist Mono by weight.
  public static func geistMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    let name: String
    switch weight {
    case .bold, .heavy, .black:
      name = DesignTokens.Typography.geistMonoBold
    case .semibold:
      name = DesignTokens.Typography.geistMonoSemiBold
    case .medium:
      name = DesignTokens.Typography.geistMonoMedium
    default:
      name = DesignTokens.Typography.geistMonoRegular
    }
    return .custom(name, size: size)
  }
}
