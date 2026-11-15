//
//  LinearVisuals.swift
//  AgentHub
//
//  Small shared visuals for the Linear board: state type, priority, labels.
//

import SwiftUI

enum LinearVisuals {
  /// Color for a workflow state type (backlog, unstarted, started, completed).
  static func stateTypeColor(_ type: String) -> Color {
    switch type {
    case "backlog": return .gray
    case "unstarted": return .secondary
    case "started": return .orange
    case "completed": return .green
    default: return .secondary
    }
  }

  /// SF Symbol for a workflow state type.
  static func stateTypeSymbol(_ type: String) -> String {
    switch type {
    case "backlog": return "circle.dotted"
    case "unstarted": return "circle"
    case "started": return "circle.lefthalf.filled"
    case "completed": return "checkmark.circle.fill"
    default: return "circle"
    }
  }

  /// Priority symbol and color (Linear priority: 0=none, 1=urgent, 2=high, 3=medium, 4=low).
  static func prioritySymbol(_ priority: Int) -> (name: String, color: Color)? {
    switch priority {
    case 1: return ("exclamationmark.triangle.fill", .red)
    case 2: return ("chevron.up", .orange)
    case 3: return ("equal", .yellow)
    case 4: return ("chevron.down", .blue)
    default: return nil
    }
  }
}

// MARK: - LinearStateIcon

struct LinearStateIcon: View {
  let stateType: String
  var size: CGFloat = 12

  var body: some View {
    Image(systemName: LinearVisuals.stateTypeSymbol(stateType))
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(LinearVisuals.stateTypeColor(stateType))
  }
}

// MARK: - LinearPriorityIcon

struct LinearPriorityIcon: View {
  let priority: Int

  var body: some View {
    if let symbol = LinearVisuals.prioritySymbol(priority) {
      Image(systemName: symbol.name)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(symbol.color)
    }
  }
}

// MARK: - LinearStatePill

struct LinearStatePill: View {
  let state: String
  let stateType: String

  var body: some View {
    let color = LinearVisuals.stateTypeColor(stateType)
    Text(state.uppercased())
      .font(.secondaryCaption)
      .tracking(0.4)
      .foregroundStyle(stateType == "unstarted" ? Color.primary.opacity(0.75) : color)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15), in: Capsule())
  }
}

// MARK: - LinearLabelChip

struct LinearLabelChip: View {
  let label: String
  let color: String

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(Color(hex: color) ?? .secondary)
        .frame(width: 6, height: 6)
      Text(label)
        .font(.secondaryCaption)
        .lineLimit(1)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      Capsule().fill(Color.primary.opacity(0.05))
    )
  }
}

// MARK: - LinearAvatar

/// Linear user avatar with an initials fallback.
struct LinearAvatar: View {
  let name: String?
  let url: URL?
  var size: CGFloat = 22

  var body: some View {
    Group {
      if let name {
        AsyncImage(url: url) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          initials(for: name)
        }
      } else {
        Image(systemName: "person.crop.circle.badge.questionmark")
          .font(.system(size: size * 0.7))
          .foregroundStyle(.secondary)
          .frame(width: size, height: size)
          .background(Color.legacySurfaceFill)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .help(name ?? "Unassigned")
  }

  private func initials(for name: String) -> some View {
    let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    let hue = Double(name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360
    return Text(letters.uppercased())
      .font(.secondaryCaption)
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(Color(hue: hue, saturation: 0.45, brightness: 0.7))
  }
}

// MARK: - Color hex helper

private extension Color {
  init?(hex: String) {
    let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
    let r = Double((value >> 16) & 0xFF) / 255
    let g = Double((value >> 8) & 0xFF) / 255
    let b = Double(value & 0xFF) / 255
    self.init(red: r, green: g, blue: b)
  }
}
