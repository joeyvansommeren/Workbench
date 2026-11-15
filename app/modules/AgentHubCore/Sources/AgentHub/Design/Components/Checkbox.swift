//
//  Checkbox.swift
//  AgentHub
//
//  A 16 pt checkbox. Matches `.checkbox` in the prototype.
//

import SwiftUI

/// A 16 x 16 checkbox with a check mark when on. The hit area is 24 x 24
/// (macOS minimum); the box still draws at 16 pt.
public struct WBCheckbox: View {
  @Binding var isChecked: Bool
  let label: String
  let accessibilityIdentifier: String?

  /// - Parameter label: What the checkbox turns on. VoiceOver reads it, so
  ///   there is no default.
  public init(
    isChecked: Binding<Bool>,
    label: String,
    accessibilityIdentifier: String? = nil
  ) {
    self._isChecked = isChecked
    self.label = label
    self.accessibilityIdentifier = accessibilityIdentifier
  }

  public var body: some View {
    Button {
      isChecked.toggle()
    } label: {
      box
        .padding(4)
        .contentShape(Rectangle())
    }
    .buttonStyle(WBCheckboxStyle())
    // `WBCheckboxBody` draws `wbFocusRing` round the box in place of the native ring.
    .focusEffectDisabled()
    .accessibilityLabel(label)
    .accessibilityValue(isChecked ? "checked" : "unchecked")
    .accessibilityAddTraits(isChecked ? .isSelected : [])
    .optionalAccessibilityIdentifier(accessibilityIdentifier)
  }

  private var box: some View {
    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
    return ZStack {
      shape.fill(isChecked ? Color.wbAccent : Color.wbSurfaceControl)
      if isChecked {
        Image(systemName: "checkmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color.wbTextOnAccent)
      } else {
        shape.strokeBorder(Color.wbBorderStrong, lineWidth: 1)
      }
    }
    .frame(width: 16, height: 16)
  }
}

/// Draws the focus ring around the 16 pt box, not the 24 pt hit area.
private struct WBCheckboxStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    WBCheckboxBody(configuration: configuration)
  }
}

private struct WBCheckboxBody: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused

  var body: some View {
    configuration.label
      .overlay {
        Color.clear
          .frame(width: 16, height: 16)
          .wbFocusRing(isFocused, cornerRadius: 4)
      }
      .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabled)
  }
}
