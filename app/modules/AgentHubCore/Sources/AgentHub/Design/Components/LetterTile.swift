//
//  LetterTile.swift
//  AgentHub
//
//  Repository identity tile: a coloured square with a letter.
//  Matches `.tile` in the prototype.
//

import SwiftUI

// MARK: - Tile colour

/// The three tile colours from the prototype. A repository gets a stable
/// colour by hashing its canonical path.
public enum RepositoryTileColor: String, CaseIterable, Sendable {
  case violet
  case teal
  case orange

  /// Stable colour for a repository path. Normalises trailing slashes
  /// and Unicode form so `forPath(p) == forPath(p + "/")`.
  /// Worktrees share their parent repo's colour when resolved through
  /// `WorktreeModuleResolver`.
  public static func forPath(_ path: String) -> RepositoryTileColor {
    let normalized = WorktreeModuleResolver.normalizedDirectoryPath(
      path.precomposedStringWithCanonicalMapping
    )
    let index = Int(fnv1a64(normalized) % UInt64(allCases.count))
    return allCases[index]
  }

  /// FNV-1a, 64 bit: stable across runs (unlike `Hasher`) and well mixed.
  /// The old `(h + byte) * 31` hash kept `h % 3` close to the byte sum, so
  /// paths with the same letters always got the same colour.
  static func fnv1a64(_ value: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01b3
    }
    return hash
  }

  @MainActor
  public var color: Color {
    switch self {
    case .violet: return .wbTileViolet
    case .teal:   return .wbTileTeal
    case .orange: return .wbTileOrange
    }
  }
}

// MARK: - Letter tile view

/// An 18 pt coloured tile with a single letter.
public struct LetterTile: View {
  let letter: Character
  let tileColor: RepositoryTileColor

  public init(letter: Character, color: RepositoryTileColor) {
    self.letter = letter
    self.tileColor = color
  }

  /// Convenience: extract the first letter from a name and pick a colour
  /// from the path.
  public init(name: String, path: String) {
    self.letter = name.first ?? "?"
    self.tileColor = RepositoryTileColor.forPath(path)
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
    Text(String(letter).uppercased())
      // Prototype `.tile`: Inter 700 11px, letter-spacing 0.
      .font(WorkbenchTypography.uiFont(size: 11, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: DesignTokens.Size.tile, height: DesignTokens.Size.tile)
      .background(tileColor.color, in: shape)
      .overlay {
        shape.strokeBorder(.black.opacity(0.15), lineWidth: 0.5)
          .allowsHitTesting(false)
      }
      .overlay {
        // `inset 0 0.5px 0 white 0.3`: the top edge only. The stroke follows
        // the corners and fades out down them, so no white ears stick out.
        shape.strokeBorder(
          LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center),
          lineWidth: 0.5
        )
        .allowsHitTesting(false)
      }
      .fixedSize()
  }
}
