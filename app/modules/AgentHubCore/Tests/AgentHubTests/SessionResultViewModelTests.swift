import Foundation
import Testing
@testable import AgentHubCore

private actor ResultTestStore: SessionResultRecipeStoreProtocol, ProjectLaunchRecipeStoreProtocol {
  var results: [SessionResult] = []
  var recipe: ProjectLaunchRecipe?
  var failAtomicSave = false
  var failRecipeLoad = false
  func setFailRecipeLoad() { failRecipeLoad = true }
  func loadSessionResults() -> [SessionResult] { results }
  func saveSessionResult(_ result: SessionResult) { results = [result] }
  func loadProjectLaunchRecipe(repositoryPath: String) throws -> ProjectLaunchRecipe? {
    if failRecipeLoad { throw CocoaError(.fileReadUnknown) }
    return recipe
  }
  func saveProjectLaunchRecipe(_ recipe: ProjectLaunchRecipe) { self.recipe = recipe }
  func setFailAtomicSave(_ value: Bool) { failAtomicSave = value }
  func saveSessionResult(_ result: SessionResult, recipe: ProjectLaunchRecipe) throws {
    if failAtomicSave { throw CocoaError(.fileWriteUnknown) }
    results = [result]
    self.recipe = recipe
  }
}

private struct ResultTestSource: ResultSourceInspecting {
  let identity: String?
  func inspect(projectPath: String) async -> ResultSourceSnapshot {
    ResultSourceSnapshot(worktreePath: projectPath, repositoryPath: "/tmp/main", identity: identity)
  }
}

@MainActor
struct SessionResultViewModelTests {
  @Test func recipeAndResultUpdateOnlyAfterAtomicSaveSucceeds() async throws {
    let store = ResultTestStore()
    let library = SessionResultLibrary(store: store)
    let model = SessionResultViewModel(
      recipeStore: store, sourceService: ResultTestSource(identity: "source"))
    let oldRecipe = ProjectLaunchRecipe(
      repositoryPath: "/tmp/main", destination: "http://localhost:3000/old")
    await store.saveProjectLaunchRecipe(oldRecipe)
    await model.load(projectPath: "/tmp/work")
    var original = SessionResult(provider: .claude, sessionID: "s", projectPath: "/tmp/work")
    original.summary = "Previous"
    try await library.save(original)
    var edited = original
    edited.summary = "Updated"
    let newRecipe = ProjectLaunchRecipe(
      repositoryPath: "/tmp/main", destination: "http://localhost:3000/new")
    await store.setFailAtomicSave(true)
    #expect(!(await model.save(edited, recipe: newRecipe, library: library)))
    #expect(model.recipe == oldRecipe)
    #expect(library.records[original.id]?.summary == "Previous")
    #expect(await store.recipe == oldRecipe)
    #expect(await store.results.first?.summary == "Previous")
    await store.setFailAtomicSave(false)
    #expect(await model.save(edited, recipe: newRecipe, library: library))
    #expect(model.recipe == newRecipe)
    #expect(library.records[original.id]?.summary == "Updated")
    #expect(await store.recipe == newRecipe)
    #expect(await store.results.first?.summary == "Updated")
  }
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
  var revealed: [URL] = []
  func reveal(_ url: URL) { revealed.append(url) }
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

@MainActor
struct LaunchRecipeRecoveryTests {
  @Test func revealsSavedNativeBuildWithoutStartingWebServer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let app = root.appendingPathComponent("app/build/Example.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try Data().write(to: app.appendingPathComponent("Contents/Info.plist"))
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ResultTestStore()
    await store.saveProjectLaunchRecipe(ProjectLaunchRecipe(repositoryPath: "/tmp/main",
      workingSubdirectory: "app", executable: "bun", nativeTarget: "build/Example.app"))
    let server = ResultTestServer()
    let health = ResultTestHealth([false])
    let opener = ResultTestOpener()
    let model = SessionResultViewModel(recipeStore: store, sourceService: ResultTestSource(identity: "source"),
      health: health, server: server, opener: opener)
    var result = SessionResult(provider: .codex, sessionID: "s", projectPath: root.path)
    result.kind = .native
    await model.open(result: result)
    #expect(opener.revealed.map(\.path) == [app.resolvingSymlinksInPath().path])
    #expect(opener.urls.isEmpty && server.launches.isEmpty)
    #expect(await health.requested.isEmpty)
    #expect(model.error == nil)
  }

  @Test func unsupportedNativeTargetsNeverOpenAWebPageOrRunACommand() async {
    for target in ["http://localhost:3000/", "simulator:Example", "build/not-an-app", "../Other.app"] {
      let server = ResultTestServer()
      let opener = ResultTestOpener()
      let model = SessionResultViewModel(recipeStore: nil, sourceService: ResultTestSource(identity: "source"),
        health: ResultTestHealth([true]), server: server, opener: opener)
      var result = SessionResult(provider: .codex, sessionID: "s", projectPath: "/tmp/work")
      result.kind = .native
      result.destination = target
      await model.open(result: result)
      #expect(model.error != nil)
      #expect(opener.urls.isEmpty && opener.revealed.isEmpty && server.launches.isEmpty)
    }
  }

  @Test func relativeWebFileUsesSavedWorkingDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = root.appendingPathComponent("web/result.html")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ResultTestStore()
    await store.saveProjectLaunchRecipe(ProjectLaunchRecipe(repositoryPath: "/tmp/main",
      workingSubdirectory: "web", destination: "result.html"))
    let opener = ResultTestOpener()
    let model = SessionResultViewModel(recipeStore: store, sourceService: ResultTestSource(identity: "source"),
      opener: opener)
    await model.open(result: SessionResult(provider: .codex, sessionID: "s", projectPath: root.path))
    #expect(opener.urls.map(\.path) == [file.resolvingSymlinksInPath().path])
    #expect(model.error == nil)
  }

  @Test func failedRecipeLoadClearsCachedRecipeAndDoesNotLaunch() async {
    let store = ResultTestStore()
    await store.saveProjectLaunchRecipe(ProjectLaunchRecipe(repositoryPath: "/tmp/main", executable: "bun",
      destination: "http://localhost:3000/old"))
    let opener = ResultTestOpener()
    let server = ResultTestServer()
    let model = SessionResultViewModel(recipeStore: store, sourceService: ResultTestSource(identity: "source"),
      health: ResultTestHealth([true]), server: server, opener: opener)
    await model.load(projectPath: "/tmp/work")
    #expect(model.recipe != nil)
    await store.setFailRecipeLoad()
    var result = SessionResult(provider: .codex, sessionID: "s", projectPath: "/tmp/other")
    result.destination = "http://localhost:3000/new"
    await model.open(result: result)
    #expect(model.recipe == nil && model.suggestedRecipe == nil)
    #expect(model.error != nil)
    #expect(opener.urls.isEmpty && server.launches.isEmpty)
  }
}
