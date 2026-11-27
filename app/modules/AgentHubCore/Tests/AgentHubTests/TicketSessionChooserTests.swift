import Testing

@testable import AgentHubCore

@MainActor
struct TicketSessionChooserTests {
  private let repository = SelectedRepository(path: "/fixture/Work")
  private let future = TicketSessionProviderDescriptor(id: "Future", name: "Future Agent")

  @Test("Confirm uses the chosen agent with both providers installed")
  func launchesChosenAgent() async {
    for provider in SessionProviderKind.allCases {
      let model = TicketSessionChooserModel()
      let installed = SessionProviderKind.allCases.map { option($0, installed: true) }
      let started = await model.start(
        providerID: provider.rawValue, repositoryPath: repository.path,
        repositories: [repository], readOptions: { installed }, directoryExists: { _ in true },
        launch: { selected, path in
          #expect(selected == provider)
          #expect(path == repository.path)
          return nil
        })
      #expect(started)
    }
  }

  @Test("One installed agent still needs an explicit choice")
  func neverFallsBack() async {
    let model = TicketSessionChooserModel()
    let options = [option(.claude, installed: false), option(.codex, installed: true)]
    model.refresh(options)
    #expect(!model.isStarting)
    #expect(!model.didStart)
    let started = await model.start(
      providerID: SessionProviderKind.claude.rawValue, repositoryPath: repository.path,
      repositories: [repository], readOptions: { options }, directoryExists: { _ in true },
      launch: { _, _ in
        Issue.record("Choosing Claude must never start Codex")
        return nil
      })
    #expect(!started)
    #expect(model.error == SessionProviderKind.claude.notInstalledHelp)
  }

  @Test("Unavailable and future providers remain visible and cannot launch")
  func unsupportedProviders() async {
    let model = TicketSessionChooserModel()
    let options = TicketSessionProviderOption.resolve(TicketSessionProviderDescriptor.catalog + [future]) { id in
      SessionProviderKind(rawValue: id).map { ($0, false) }
    }
    #expect(options.last?.name == future.name)
    #expect(options.last?.provider == nil)
    for expected in options {
      let started = await model.start(
        providerID: expected.id, repositoryPath: repository.path,
        repositories: [repository], readOptions: { options }, directoryExists: { _ in true },
        launch: { _, _ in
          Issue.record("This provider has no usable adapter")
          return nil
        })
      #expect(!started)
      #expect(model.options.map(\.name).contains(expected.name))
      #expect(model.error == expected.unavailableReason)
    }
  }

  @Test("Confirm notices a deleted repository and a provider removed since opening")
  func revalidatesAtConfirmation() async {
    let model = TicketSessionChooserModel()
    let installed = option(.claude, installed: true)
    model.refresh([installed])
    let missingProvider = await model.start(
      providerID: installed.id, repositoryPath: repository.path, repositories: [repository],
      readOptions: { [option(.claude, installed: false)] }, directoryExists: { _ in true },
      launch: { _, _ in
        Issue.record("A removed provider cannot start")
        return nil
      })
    #expect(!missingProvider)

    let missingRepository = await model.start(
      providerID: installed.id, repositoryPath: repository.path, repositories: [repository],
      readOptions: { [installed] }, directoryExists: { _ in false },
      launch: { _, _ in
        Issue.record("A deleted repository cannot start")
        return nil
      })
    #expect(!missingRepository)
    #expect(model.error == "This repository is no longer available. Choose another repository.")
  }

  @Test("A pending and a completed start both reject a repeated confirmation")
  func startsExactlyOnce() async {
    let model = TicketSessionChooserModel()
    let installed = option(.codex, installed: true)
    let started = await model.start(
      providerID: installed.id, repositoryPath: repository.path, repositories: [repository],
      readOptions: { [installed] }, directoryExists: { _ in true },
      launch: { _, _ in
        #expect(model.isStarting)
        let repeated = await model.start(
          providerID: installed.id, repositoryPath: repository.path, repositories: [repository],
          readOptions: { [installed] }, directoryExists: { _ in true },
          launch: { _, _ in
            Issue.record("The first start must finish before accepting another")
            return nil
          })
        #expect(!repeated)
        return nil
      })
    #expect(started)
    let repeated = await model.start(
      providerID: installed.id, repositoryPath: repository.path, repositories: [repository],
      readOptions: { [installed] }, directoryExists: { _ in true },
      launch: { _, _ in
        Issue.record("A successful start must stay reserved until the sheet closes")
        return nil
      })
    #expect(!repeated)
  }

  @Test("Failure leaves the chooser open and allows another explicit start")
  func retriesAfterFailure() async {
    let model = TicketSessionChooserModel()
    let installed = option(.codex, installed: true)
    let failed = await model.start(
      providerID: installed.id, repositoryPath: repository.path, repositories: [repository],
      readOptions: { [installed] }, directoryExists: { _ in true },
      launch: { _, _ in "Could not save session identity." })
    #expect(!failed)
    #expect(model.error == "Could not save session identity.")
    #expect(!model.isStarting)
    #expect(!model.didStart)
    let retried = await model.start(
      providerID: installed.id, repositoryPath: repository.path, repositories: [repository],
      readOptions: { [installed] }, directoryExists: { _ in true },
      launch: { _, _ in nil })
    #expect(retried)
    #expect(model.error == nil)
  }

  private func option(_ provider: SessionProviderKind, installed: Bool) -> TicketSessionProviderOption {
    TicketSessionProviderOption(
      id: provider.rawValue, name: provider.agentDisplayName,
      provider: provider, isInstalled: installed)
  }
}
