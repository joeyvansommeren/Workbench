import Foundation
import Testing
@testable import AgentHubCore

private actor ResultTestStore: SessionResultStoreProtocol, ProjectLaunchRecipeStoreProtocol {
  var results: [SessionResult] = []
  var recipe: ProjectLaunchRecipe?
  func loadSessionResults() -> [SessionResult] { results }
  func saveSessionResult(_ result: SessionResult) { results = [result] }
  func loadProjectLaunchRecipe(repositoryPath: String) -> ProjectLaunchRecipe? { recipe }
  func saveProjectLaunchRecipe(_ recipe: ProjectLaunchRecipe) { self.recipe = recipe }
}

private struct ResultTestSource: ResultSourceInspecting {
  let identity: String?
  func inspect(projectPath: String) async -> ResultSourceSnapshot {
    ResultSourceSnapshot(worktreePath: projectPath, repositoryPath: "/tmp/main", identity: identity)
  }
}

@MainActor
struct SessionResultViewModelTests {
  @Test func sourceChangeRejectsAcceptanceWithoutSavingIt() async throws {
    let store = ResultTestStore()
    let library = SessionResultLibrary(store: store)
    let model = SessionResultViewModel(recipeStore: store, sourceService: ResultTestSource(identity: "new"))
    var result = SessionResult(provider: .claude, sessionID: "s", projectPath: "/tmp/work")
    result.sourceIdentity = "old"
    try await library.save(result)
    await model.decide(.accepted, result: result, library: library)
    #expect(library.records[result.id]?.decision == SessionProductDecision.none)
    #expect(model.error != nil)
  }

  @Test func unknownSourceAcceptanceIsExplicitAndRemainsUnverified() async throws {
    let store = ResultTestStore()
    let library = SessionResultLibrary(store: store)
    let model = SessionResultViewModel(recipeStore: store, sourceService: ResultTestSource(identity: nil))
    let result = SessionResult(provider: .codex, sessionID: "s", projectPath: "/tmp/work")
    try await library.save(result)
    await model.decide(.accepted, result: result, library: library)
    let saved = try #require(library.records[result.id])
    #expect(saved.decision == .accepted)
    #expect(saved.freshness(comparedTo: model.source?.identity) == .unknown)
  }

  @Test func activityInvalidatesPreviouslyCheckedSource() async {
    let model = SessionResultViewModel(recipeStore: nil, sourceService: ResultTestSource(identity: "content"))
    await model.load(projectPath: "/tmp/work")
    #expect(model.source?.identity == "content")
    model.invalidateSource()
    #expect(model.source?.identity == nil)
    #expect(model.source?.worktreePath == "/tmp/work")
  }

  @Test func editingAnAcceptedResultInvalidatesItsDecision() async throws {
    let store = ResultTestStore()
    let library = SessionResultLibrary(store: store)
    let model = SessionResultViewModel(recipeStore: store, sourceService: ResultTestSource(identity: "new"))
    var result = SessionResult(provider: .claude, sessionID: "s", projectPath: "/tmp/work")
    result.decision = .accepted
    let revision = result.revision
    #expect(await model.save(result, recipe: nil, library: library))
    #expect(library.records[result.id]?.decision == SessionProductDecision.none)
    #expect(library.records[result.id]?.revision != revision)
  }
}


private actor ResultTestHealth: ResultHealthChecking {
  private var responses: [Bool]
  private(set) var requested: [URL] = []
  init(_ responses: [Bool]) { self.responses = responses }
  func isReachable(_ url: URL) -> Bool {
    requested.append(url)
    return responses.isEmpty ? false : responses.removeFirst()
  }
}

@MainActor
private final class ResultTestServer: ResultServerStarting {
  var launches: [(ProjectLaunchRecipe, String, String)] = []
  var restarts: [(ProjectLaunchRecipe, String, String)] = []
  var active: ResultServerRecipeIdentity?
  var ownsProcess = true
  func validate(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) throws {
    guard let active else { return }
    let target = try ProjectLaunchRecipe.destinationURL(recipe.destination, projectPath: worktreePath)
    let requested = ResultServerRecipeIdentity(projectPath: try recipe.workingPath(in: worktreePath),
      executable: recipe.executable, arguments: recipe.arguments, port: target.port ?? 80)
    _ = try DevServerManager.resultRecipeAction(state: .waitingForReady, active: active,
      requested: requested, ownsProcess: ownsProcess, restart: false)
  }
  func restart(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) async throws {
    guard ownsProcess else { throw ResultRecipeError.notOwned }
    restarts.append((recipe, key, worktreePath))
  }
  func start(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) async throws {
    launches.append((recipe, key, worktreePath))
  }
}

@MainActor
private final class ResultTestOpener: ResultDestinationOpening {
  var urls: [URL] = []
  func open(_ url: URL) -> Bool { urls.append(url); return true }
}

@MainActor
struct ResultLaunchViewModelTests {
  @Test func changedRecipeOffersExplicitRestartEvenWhenOldDestinationIsReachable() async throws {
    let store = ResultTestStore()
    let recipe = ProjectLaunchRecipe(repositoryPath: "/tmp/main", executable: "bun", arguments: ["new-dev"],
      destination: "http://localhost:3001/")
    await store.saveProjectLaunchRecipe(recipe)
    let server = ResultTestServer()
    server.active = ResultServerRecipeIdentity(projectPath: "/tmp/work", executable: "bun", arguments: ["old-dev"], port: 3000)
    let health = ResultTestHealth([true])
    let opener = ResultTestOpener()
    let model = SessionResultViewModel(recipeStore: store, sourceService: ResultTestSource(identity: "source"),
      health: health, server: server, opener: opener)
    let result = SessionResult(provider: .codex, sessionID: "s", projectPath: "/tmp/work")
    let destination = "http://localhost:3001/alternative?mode=edit#dialog"
    await model.open(result: result, destination: destination)
    #expect(model.restartDestination == destination)
    #expect(opener.urls.isEmpty && server.restarts.isEmpty && server.launches.isEmpty)
    await model.open(result: result, destination: destination, restart: true)
    #expect(server.restarts.count == 1)
    #expect(server.restarts.first?.0.arguments == ["new-dev"])
    #expect(server.restarts.first?.0.destination == destination)
    #expect(server.restarts.first?.1 == result.id + ":result")
    #expect(opener.urls.map(\.absoluteString) == [destination])
    #expect(model.error == nil && model.restartDestination == nil)
  }

  @Test func lostOwnershipRefusesRecoveryWithoutOpeningOrRestarting() async throws {
    let store = ResultTestStore()
    await store.saveProjectLaunchRecipe(ProjectLaunchRecipe(repositoryPath: "/tmp/main", executable: "bun",
      arguments: ["dev"], destination: "http://localhost:3000/"))
    let server = ResultTestServer()
    server.ownsProcess = false
    let opener = ResultTestOpener()
    let model = SessionResultViewModel(recipeStore: store, sourceService: ResultTestSource(identity: "source"),
      health: ResultTestHealth([true]), server: server, opener: opener)
    let result = SessionResult(provider: .codex, sessionID: "s", projectPath: "/tmp/work")
    await model.open(result: result, restart: true)
    #expect(server.restarts.isEmpty && opener.urls.isEmpty)
    #expect(model.restartDestination == nil && model.error != nil)
  }

  @Test func reachableExactResultDoesNotStartACommand() async throws {
    let health = ResultTestHealth([true])
    let server = ResultTestServer()
    let opener = ResultTestOpener()
    let model = SessionResultViewModel(recipeStore: nil, sourceService: ResultTestSource(identity: "source"),
      health: health, server: server, opener: opener)
    var result = SessionResult(provider: .codex, sessionID: "s", projectPath: "/tmp/work")
    result.destination = "http://localhost:3000/profile?mode=edit#dialog"
    await model.open(result: result)
    #expect(opener.urls.map(\.absoluteString) == [result.destination])
    #expect(server.launches.isEmpty)
    #expect(model.error == nil)
  }

  @Test func unreachableResultUsesSavedRecipeInCurrentWorktree() async throws {
    let store = ResultTestStore()
    let recipe = ProjectLaunchRecipe(repositoryPath: "/tmp/main", workingSubdirectory: "app",
      executable: "bun", arguments: ["run", "dev"], destination: "http://localhost:3000/")
    await store.saveProjectLaunchRecipe(recipe)
    let health = ResultTestHealth([false, true])
    let server = ResultTestServer()
    let opener = ResultTestOpener()
    let model = SessionResultViewModel(recipeStore: store, sourceService: ResultTestSource(identity: "source"),
      health: health, server: server, opener: opener)
    var result = SessionResult(provider: .codex, sessionID: "s", projectPath: "/tmp/work")
    result.destination = "http://localhost:3000/specific?state=open"
    await model.open(result: result)
    let launch = try #require(server.launches.first)
    #expect(launch.0.destination == result.destination)
    #expect(launch.0.arguments == ["run", "dev"])
    #expect(launch.1 == result.id + ":result")
    #expect(launch.2 == "/tmp/work")
    #expect(opener.urls.map(\.absoluteString) == [result.destination])
    #expect(await health.requested.allSatisfy { $0.absoluteString == result.destination })
  }

  @Test func missingRecipeDoesNotInventOrLaunchACommand() async {
    let server = ResultTestServer()
    let opener = ResultTestOpener()
    let model = SessionResultViewModel(recipeStore: nil, sourceService: ResultTestSource(identity: nil),
      health: ResultTestHealth([false]), server: server, opener: opener)
    var result = SessionResult(provider: .claude, sessionID: "s", projectPath: "/tmp/work")
    result.destination = "http://localhost:3000/result"
    await model.open(result: result)
    #expect(server.launches.isEmpty)
    #expect(opener.urls.isEmpty)
    #expect(model.error != nil)
  }
}
