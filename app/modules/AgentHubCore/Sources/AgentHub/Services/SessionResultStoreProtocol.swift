import Foundation

protocol SessionResultStoreProtocol: Sendable {
  func loadSessionResults() async throws -> [SessionResult]
  func saveSessionResult(_ result: SessionResult) async throws
}

protocol ProjectLaunchRecipeStoreProtocol: Sendable {
  func loadProjectLaunchRecipe(repositoryPath: String) async throws -> ProjectLaunchRecipe?
  func saveProjectLaunchRecipe(_ recipe: ProjectLaunchRecipe) async throws
}
