import Foundation
import Testing

@testable import AgentHubGitHub

struct GitHubReviewedPublicationTests {
  private let repository = GitHubRepositoryIdentity(owner: "owner", repository: "project")

  @Test("Readback prefers an open PR and includes both commit IDs")
  func readsCurrentScope() throws {
    let result = try GitHubCLIService.decodePublicationPullRequests(
      payload([request(12, state: "closed"), request(8, state: "open")]),
      repository: repository, branch: "codex/topic")
    #expect(result.map(\.number) == [8, 12])
    #expect(result.map(\.isOpen) == [true, false])
    #expect(result.first?.head == "head-commit")
    #expect(result.first?.baseOID == "base-commit")
    #expect(result.first?.base == "main")
  }

  @Test("A result for a different repository is refused")
  func refusesWrongRepository() {
    #expect(throws: GitHubCLIError.self) {
      try GitHubCLIService.decodePublicationPullRequests(
        payload([request(8, state: "open", baseRepository: "owner/other")]),
        repository: repository, branch: "codex/topic")
    }
  }

  @Test("A repository-pinned ref read checks the advertised names and can report an unpublished source")
  func readsPinnedRefs() throws {
    let base = String(repeating: "b", count: 40)
    let head = String(repeating: "a", count: 40)
    let published = refPayload(owner: "owner/project", base: base, headRef: "codex/topic", head: head)
    #expect(try GitHubCLIService.decodePublicationRefs(
      published, repository: repository, base: "main", branch: "codex/topic") == .init(base: base, head: head))
    let unpushed = refPayload(owner: "owner/project", base: base, headRef: nil, head: head)
    #expect(try GitHubCLIService.decodePublicationRefs(
      unpushed, repository: repository, base: "main", branch: "codex/topic") == .init(base: base, head: nil))

    for unexpected in [
      refPayload(owner: "other/project", base: base, headRef: "codex/topic", head: head),
      refPayload(owner: "owner/project", base: base, headRef: "codex/other", head: head),
    ] {
      #expect(throws: GitHubCLIError.self) {
        try GitHubCLIService.decodePublicationRefs(
          unexpected, repository: repository, base: "main", branch: "codex/topic")
      }
    }
  }

  private func refPayload(owner: String, base: String, headRef: String?, head: String) -> Data {
    let headValue = headRef.map { """
      {"name":"\($0)","target":{"oid":"\(head)"}}
      """ } ?? "null"
    return Data("""
      {"data":{"repository":{"nameWithOwner":"\(owner)",
      "base":{"name":"main","target":{"oid":"\(base)"}},"head":\(headValue)}}}
      """.utf8)
  }

  private func payload(_ records: [String]) -> Data {
    Data("[[\(records.joined(separator: "],["))]]".utf8)
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
