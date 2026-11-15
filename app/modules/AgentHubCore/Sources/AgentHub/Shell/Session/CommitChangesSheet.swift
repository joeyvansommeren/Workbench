import SwiftUI

struct CommitChangesSheet: View {
  @Bindable var model: CommitChangesReviewModel
  let onCommitted: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(model.phase == .committed ? "Changes committed" : "Review commit")
        .font(.title2.weight(.semibold))
      if model.phase == .preparing {
        ProgressView("Reading the worktree…")
      }
      if let snapshot = model.snapshot {
        target(snapshot)
        fileList(snapshot)
        if model.phase == .prepared, !snapshot.entries.isEmpty {
          TextField("Commit message", text: $model.message, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(3...6)
          Text(
            "Commits the listed file versions locally. Hooks and signing still apply. This does not push or confirm that tests passed."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
      }
      feedback
      actions
    }
    .padding(24)
    .frame(width: 600)
    .interactiveDismissDisabled(model.phase == .executing)
    .task { await model.prepare() }
  }

  private func target(_ snapshot: CommitChangeSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Worktree: \(snapshot.worktreePath)")
      Text("Branch: \(snapshot.branch)")
      Text("Current commit: \(snapshot.head)").font(.system(.caption, design: .monospaced))
    }
    .textSelection(.enabled)
  }

  private func fileList(_ snapshot: CommitChangeSnapshot) -> some View {
    Group {
      if snapshot.entries.isEmpty {
        Text("There are no uncommitted files in this worktree.")
      } else {
        Text("\(snapshot.entries.count) files included")
          .font(.headline)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(snapshot.entries) { entry in
              VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayPath).font(.system(.body, design: .monospaced))
                if let original = entry.originalPath {
                  Text("Renamed from \(original.debugDescription)").font(.caption)
                }
                Text(status(entry)).font(.caption).foregroundStyle(.secondary)
              }
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .frame(maxHeight: 260)
      }
    }
  }

  private var feedback: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.phase == .executing { ProgressView("Committing the reviewed files…") }
      if let receipt = model.receipt {
        Text("Commit \(receipt.commitID) on \(receipt.branch)")
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
      }
      if let error = model.error {
        Text(model.phase == .unconfirmed ? "Commit status unconfirmed" : "Commit stopped")
          .font(.headline)
        Text(error).textSelection(.enabled)
      }
    }
  }

  private var actions: some View {
    HStack {
      Spacer()
      Button(model.phase == .prepared ? "Cancel" : "Close") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .disabled(model.phase == .executing)
      if model.phase == .prepared, !(model.snapshot?.entries.isEmpty ?? true) {
        Button("Commit reviewed files") {
          Task {
            await model.commit()
            if model.phase == .committed { onCommitted() }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canCommit)
      }
    }
  }

  private func status(_ entry: CommitChangeSnapshot.Entry) -> String {
    let change: String
    if entry.originalPath != nil {
      change = "Renamed"
    } else if entry.mode == "0" {
      change = "Deleted"
    } else if entry.status == "??" {
      change = "New file"
    } else if entry.status.contains("A") {
      change = "Added"
    } else {
      change = "Modified"
    }
    let staging = entry.status == "??" || entry.status.first == " " ? "Unstaged" : "Staged"
    return "\(change) · \(staging) · mode \(entry.mode)"
  }
}
