import Foundation
import Testing

@testable import AgentHubGitHub

@Suite("Repository identity resolver")
struct GitHubRepositoryIdentityResolverTests {
  @Test("Resolves every remote on the requested host")
  func forkAndUpstream() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func git(_ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-C", directory.path] + arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
    }
    try git(["init"])
    try git(["remote", "add", "origin", "https://github.com/fork/shared.git"])
    try git(["remote", "add", "upstream", "git@github.com:acme/shared.git"])
    try git(["remote", "add", "enterprise", "https://enterprise.example/acme/shared.git"])
    let resolver = GitHubRepositoryIdentityResolver()
    let github = await resolver.resolveIdentities(at: directory.path, expectedHost: "github.com")
    #expect(
      github == [
        GitHubRepositoryIdentity(owner: "fork", repository: "shared"),
        GitHubRepositoryIdentity(owner: "acme", repository: "shared"),
      ])
    let enterprise = await resolver.resolveIdentities(
      at: directory.path, expectedHost: "enterprise.example")
    #expect(
      enterprise == [
        GitHubRepositoryIdentity(owner: "acme", repository: "shared", host: "enterprise.example")
      ])
  }
}
