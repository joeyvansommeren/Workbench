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

  /// Stable colour for a repository path. Worktrees share their parent
  /// repo's colour when resolved through `WorktreeModuleResolver`.
  public static func forPath(_ path: String) -> RepositoryTileColor {
    let hash = path.utf8.reduce(0) { ($0 &+ UInt64($1)) &* 31 }
    let index = Int(hash % UInt64(allCases.count))
    return allCases[index]
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
    Text(String(letter).uppercased())
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: DesignTokens.Size.tile, height: DesignTokens.Size.tile)
      .background(tileColor.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
      .overlay {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
          .strokeBorder(.black.opacity(0.15), lineWidth: 0.5)
          .overlay(alignment: .top) {
            Rectangle()
              .fill(.white.opacity(0.3))
              .frame(height: 0.5)
              .clipShape(
                UnevenRoundedRectangle(
                  topLeadingRadius: DesignTokens.Radius.small,
                  bottomLeadingRadius: 0,
                  bottomTrailingRadius: 0,
                  topTrailingRadius: DesignTokens.Radius.small
                )
              )
          }
          .allowsHitTesting(false)
      }
      .fixedSize()
  }
}
