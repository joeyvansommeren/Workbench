import Foundation
import Testing

@testable import AgentHubGitHub

struct GitHubReviewedPublicationTests {
  private let repository = GitHubRepositoryIdentity(owner: "owner", repository: "project")

  @Test("Readback prefers an open PR and includes both commit IDs")
  func readsCurrentScope() throws {
    let result = try GitHubCLIService.decodePublicationPullRequest(
      payload([request(12, state: "closed"), request(8, state: "open")]),
      repository: repository, branch: "codex/topic")
    #expect(result?.number == 8)
    #expect(result?.head == "head-commit")
    #expect(result?.baseOID == "base-commit")
    #expect(result?.base == "main")
  }

  @Test("A result for a different repository is refused")
  func refusesWrongRepository() {
    #expect(throws: GitHubCLIError.self) {
      try GitHubCLIService.decodePublicationPullRequest(
        payload([request(8, state: "open", baseRepository: "owner/other")]),
        repository: repository, branch: "codex/topic")
    }
  }

  private func payload(_ records: [String]) -> Data {
    Data("[\(records.joined(separator: ","))]".utf8)
  }

  private func request(_ number: Int, state: String, baseRepository: String = "owner/project") -> String {
    """
    {
      "number": \(number),
      "state": "\(state)",
      "html_url": "https://github.com/owner/project/pull/\(number)",
      "head": {"ref":"codex/topic","sha":"head-commit","repo":{"full_name":"owner/project"}},
      "base": {"ref":"main","sha":"base-commit","repo":{"full_name":"\(baseRepository)"}}
    }
    """
  }
}
