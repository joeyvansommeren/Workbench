//
//  Checkbox.swift
//  AgentHub
//
//  A 16 pt checkbox. Matches `.checkbox` in the prototype.
//

import SwiftUI

/// A 16 x 16 checkbox with a check mark when on.
public struct WBCheckbox: View {
  @Binding var isChecked: Bool
  let label: String
  let accessibilityIdentifier: String?

  public init(
    isChecked: Binding<Bool>,
    label: String = "Checkbox",
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
      ZStack {
        RoundedRectangle(cornerRadius: 4)
          .fill(isChecked ? Color.wbAccent : Color.wbSurfaceControl)
        if !isChecked {
          RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.wbBorderStrong, lineWidth: 1)
        }
        if isChecked {
          Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.wbTextOnAccent)
        }
      }
      .frame(width: 16, height: 16)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityValue(isChecked ? "checked" : "unchecked")
    .accessibilityAddTraits(isChecked ? .isSelected : [])
    .accessibilityIdentifier(accessibilityIdentifier ?? "")
  }
}
