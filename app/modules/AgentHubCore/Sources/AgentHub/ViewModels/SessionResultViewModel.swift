import AppKit
import Foundation

@MainActor
@Observable
final class SessionResultViewModel {
  private(set) var source: ResultSourceSnapshot?
  private(set) var recipe: ProjectLaunchRecipe?
  private(set) var suggestedRecipe: ProjectLaunchRecipe?
  private(set) var error: String?
  private(set) var isOpening = false
  private(set) var launchMessage: String?
  private(set) var restartDestination: String?
  private var observationGeneration = 0
  private let sourceService: any ResultSourceInspecting
  private let health: any ResultHealthChecking
  private let server: any ResultServerStarting
  private let opener: any ResultDestinationOpening
  private let recipeStore: (any ProjectLaunchRecipeStoreProtocol)?

  init(recipeStore: (any ProjectLaunchRecipeStoreProtocol)?,
    sourceService: any ResultSourceInspecting = ResultSourceService(),
    health: any ResultHealthChecking = ResultHealthService(),
    server: (any ResultServerStarting)? = nil, opener: (any ResultDestinationOpening)? = nil) {
    self.recipeStore = recipeStore
    self.sourceService = sourceService
    self.health = health
    self.server = server ?? ResultServerStarter()
    self.opener = opener ?? ResultDestinationOpener()
  }

  func invalidateSource() {
    observationGeneration += 1
    if let source {
      self.source = ResultSourceSnapshot(worktreePath: source.worktreePath,
        repositoryPath: source.repositoryPath, identity: nil)
    }
  }

  func load(projectPath: String) async {
    recipe = nil
    suggestedRecipe = nil
    let generation = observationGeneration
    let inspected = await sourceService.inspect(projectPath: projectPath)
    source = generation == observationGeneration ? inspected : ResultSourceSnapshot(
      worktreePath: inspected.worktreePath, repositoryPath: inspected.repositoryPath, identity: nil)
    do {
      if let source {
        recipe = try await recipeStore?.loadProjectLaunchRecipe(repositoryPath: source.repositoryPath)
        if recipe == nil {
          let detected = await Task.detached { DevServerManager.detectProject(at: projectPath) }.value
          let prefix = source.worktreePath + "/"
          let subdirectory = projectPath.hasPrefix(prefix) ? String(projectPath.dropFirst(prefix.count)) : ""
          var suggestion = ProjectLaunchRecipe(repositoryPath: source.repositoryPath, workingSubdirectory: subdirectory)
          if detected.framework.requiresDevServer || detected.framework == .unknown {
            suggestion.executable = detected.command
            suggestion.arguments = detected.arguments
            if suggestion.arguments.last == "--port" || suggestion.arguments.last == "-p" {
              suggestion.arguments.append(String(detected.defaultPort))
            }
          }
          suggestedRecipe = suggestion
        }
      }
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  func save(_ definition: SessionResult, recipe: ProjectLaunchRecipe?, library: SessionResultLibrary) async -> Bool {
    source = await sourceService.inspect(projectPath: definition.projectPath)
    var result = definition
    result.revise(sourceIdentity: source?.identity)
    do {
      var validatedRecipe = recipe
      if validatedRecipe != nil {
        guard recipeStore != nil, let source else { throw ResultLaunchError.unavailableStore }
        validatedRecipe?.repositoryPath = source.repositoryPath
        if let validatedRecipe {
          let workingPath = try validatedRecipe.workingPath(in: source.worktreePath)
          if !validatedRecipe.destination.isEmpty {
            _ = try ProjectLaunchRecipe.destinationURL(
              validatedRecipe.destination, projectPath: source.worktreePath, relativeTo: workingPath)
          }
        }
      }
      try await library.save(result, recipe: validatedRecipe)
      if let validatedRecipe { self.recipe = validatedRecipe }
      error = nil
      return true
    } catch { self.error = error.localizedDescription; return false }
  }

  func decide(_ decision: SessionProductDecision, result: SessionResult,
    correction: String = "", library: SessionResultLibrary) async {
    let generation = observationGeneration
    source = await sourceService.inspect(projectPath: result.projectPath)
    guard generation == observationGeneration,
      library.records[result.id]?.revision == result.revision else {
      invalidateSource()
      error = "The result changed during review. Refresh the evidence and try again."
      return
    }
    guard decision != .accepted || result.freshness(comparedTo: source?.identity) != .stale else {
      error = ResultLaunchError.stale.localizedDescription; return
    }
    var updated = result
    updated.decision = decision
    updated.decidedAt = Date()
    updated.correction = correction
    do { try await library.save(updated); error = nil }
    catch { self.error = error.localizedDescription }
  }

  func open(result: SessionResult, destination override: String? = nil, restart: Bool = false) async {
    guard !isOpening else { return }
    isOpening = true
    restartDestination = nil
    launchMessage = nil
    var requestedDestination: String?
    defer { isOpening = false }
    do {
      await load(projectPath: result.projectPath)
      try Task.checkCancellation()
      // A failed recipe load must not launch with stale settings from another repository.
      if error != nil { throw ResultLaunchError.unavailableStore }
      let fallback = result.kind == .native ? recipe?.nativeTarget ?? "" : recipe?.destination ?? ""
      let destination = override ?? (result.destination.isEmpty ? fallback : result.destination)
      requestedDestination = destination
      let root = source?.worktreePath ?? result.projectPath
      if result.kind == .native {
        let nativeRecipe = recipe ?? ProjectLaunchRecipe(repositoryPath: source?.repositoryPath ?? root)
        let target = try nativeRecipe.nativeBuildURL(in: root, destination: destination)
        try Task.checkCancellation()
        opener.reveal(target)
        launchMessage = "Revealed the requested build. Its version and starting state are not verified."
        error = nil
        return
      }
      let workingPath = try recipe?.workingPath(in: root) ?? root
      let url = try ProjectLaunchRecipe.destinationURL(destination, projectPath: root, relativeTo: workingPath)
      var launchRecipe = recipe
      launchRecipe?.destination = url.absoluteString
      if let launchRecipe, !launchRecipe.executable.isEmpty, !url.isFileURL,
        ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "") {
        if restart {
          try await server.restart(recipe: launchRecipe, key: result.id + ":result", worktreePath: root)
        } else {
          try server.validate(recipe: launchRecipe, key: result.id + ":result", worktreePath: root)
        }
      }
      if url.isFileURL {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ResultLaunchError.missingFile }
      } else {
        var status = await health.status(of: url)
        try Task.checkCancellation()
        if status == .unreachable {
          guard var recipe, !recipe.executable.isEmpty else { throw ResultLaunchError.unreachable }
          // The exact selected route is also the launch health target; never silently use a homepage.
          recipe.destination = url.absoluteString
          if !restart { try await server.start(recipe: recipe, key: result.id + ":result", worktreePath: root) }
          for _ in 0..<10 {
            try Task.checkCancellation()
            status = await health.status(of: url)
            try Task.checkCancellation()
            if status != .unreachable { break }
            try await Task.sleep(for: .milliseconds(400))
          }
        }
        switch status {
        case .reachable: break
        // Only the path is shown: a sign-in query can carry tokens.
        case .redirected(let finalURL): throw ResultLaunchError.redirected(finalURL.path)
        case .unreachable: throw ResultLaunchError.unreachable
        }
      }
      try Task.checkCancellation()
      guard opener.open(url) else { throw ResultLaunchError.unsupportedDestination }
      launchMessage = "Opened the requested destination. Check the version and starting state."
      error = nil
    } catch is CancellationError { launchMessage = "Opening cancelled." }
    catch ResultRecipeError.changed {
      restartDestination = requestedDestination
      error = ResultRecipeError.changed.localizedDescription
    }
    catch { self.error = error.localizedDescription }
  }
}
