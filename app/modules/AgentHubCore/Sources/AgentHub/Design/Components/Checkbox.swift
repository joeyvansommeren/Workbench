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

  public init(isChecked: Binding<Bool>) {
    self._isChecked = isChecked
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
    .accessibilityAddTraits(isChecked ? .isSelected : [])
  }
}
