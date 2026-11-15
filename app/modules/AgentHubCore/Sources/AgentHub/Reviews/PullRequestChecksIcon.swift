//
//  PullRequestChecksIcon.swift
//  AgentHub
//
//  The checks icon of the new shell's Reviews table and detail.
//

import SwiftUI

/// The 14 pt checks icon: pass, fail or pending.
struct PullRequestChecksIcon: View {
  let state: PullRequestChecksState

  var body: some View {
    Image(systemName: state.systemImage)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(color)
      .frame(width: 14, height: 14)
      .fixedSize()
      .accessibilityLabel(state.accessibilityLabel)
  }

  private var color: Color {
    switch state {
    case .pass: return .wbStatusReadyFill
    case .fail: return .wbStatusErrorFill
    case .pending: return .wbStatusIdleFill
    }
  }
}
