import SwiftUI

struct SessionResultEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State var result: SessionResult
  @State private var recipe: ProjectLaunchRecipe
  @State private var argumentLines: String
  @State private var isSaving = false
  @State private var saveFailed = false
  let onSave: (SessionResult, ProjectLaunchRecipe) async -> Bool

  init(result: SessionResult, recipe: ProjectLaunchRecipe?, repositoryPath: String,
    onSave: @escaping (SessionResult, ProjectLaunchRecipe) async -> Bool) {
    _result = State(initialValue: result)
    let recipe = recipe ?? ProjectLaunchRecipe(repositoryPath: repositoryPath)
    _recipe = State(initialValue: recipe)
    _argumentLines = State(initialValue: recipe.arguments.joined(separator: "\n"))
    self.onSave = onSave
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("Set up result").font(.title2).padding()
      Form {
        Section("What changed") {
          Picker("Output", selection: $result.kind) {
            ForEach(SessionResultKind.allCases, id: \.self) { Text($0.label).tag($0) }
          }
          TextField("Change summary", text: $result.summary, axis: .vertical)
          TextField("Affected screens, states or files", text: $result.affectedTargets, axis: .vertical)
          TextField("Exact URL or file path", text: $result.destination)
          TextField("Starting state and steps", text: $result.expectedState, axis: .vertical)
          TextField("Version or build label (optional)", text: $result.versionLabel)
        }
        if result.kind == .prototype {
          Section("Named alternatives") {
            ForEach($result.alternatives) { $alternative in
              HStack {
                TextField("Name", text: $alternative.name)
                TextField("Exact destination", text: $alternative.destination)
                Button("Remove") { result.alternatives.removeAll { $0.id == alternative.id } }
              }
            }
            Button("Add alternative") { result.alternatives.append(SessionResultAlternative(name: "", destination: "")) }
          }
        }
        Section("Repository launch recipe (optional)") {
          Text("Reused in this repository. Commands run only when you open a result that needs its server.")
            .font(.caption).foregroundStyle(.secondary)
          TextField("Working subdirectory", text: $recipe.workingSubdirectory)
          TextField("Executable", text: $recipe.executable)
          TextField("Arguments — one per line", text: $argumentLines, axis: .vertical)
          TextField("Default exact URL or path", text: $recipe.destination)
          TextField("Required state", text: $recipe.expectedState, axis: .vertical)
        }
        if saveFailed { Text("Could not save. Check the paths and try again.").foregroundStyle(.red) }
      }.formStyle(.grouped)
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(isSaving ? "Saving…" : "Save result") {
          isSaving = true
          recipe.arguments = argumentLines.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
          Task {
            let saved = await onSave(result, recipe)
            isSaving = false
            saveFailed = !saved
            if saved { dismiss() }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isSaving || result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.padding()
    }.frame(width: 620, height: 650)
  }
}
