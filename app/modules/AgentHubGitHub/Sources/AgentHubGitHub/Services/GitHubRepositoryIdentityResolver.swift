//
//  GitHubRepositoryIdentityResolver.swift
//  AgentHub
//
//  Resolves a local checkout to its GitHub owner/repository without network I/O.
//

import Foundation

public struct GitHubRepositoryIdentity: Equatable, Hashable, Sendable {
  public let host: String
  public let owner: String
  public let repository: String

  public init(owner: String, repository: String, host: String = "github.com") {
    self.host = host.lowercased()
    self.owner = owner
    self.repository = repository
  }

  public init?(remoteURL: String, expectedHost: String = "github.com") {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let path: String

    if let components = URLComponents(string: trimmed),
      components.scheme != nil,
      let host = components.host?.lowercased(),
      host == expectedHost.lowercased()
        || (expectedHost == "github.com" && host == "www.github.com")
    {
      path = components.path
    } else if let separator = trimmed.firstIndex(of: ":") {
      let host = trimmed[..<separator]
        .split(separator: "@", omittingEmptySubsequences: false)
        .last?
        .lowercased()
      guard
        host == expectedHost.lowercased()
          || (expectedHost == "github.com" && host == "www.github.com")
      else { return nil }
      path = String(trimmed[trimmed.index(after: separator)...])
    } else {
      return nil
    }

    let parts = path
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
    guard parts.count >= 2 else { return nil }

    let repository = parts[1].hasSuffix(".git")
      ? String(parts[1].dropLast(4))
      : parts[1]
    guard !parts[0].isEmpty, !repository.isEmpty else { return nil }

    self.host = expectedHost.lowercased()
    self.owner = parts[0]
    self.repository = repository
  }
}

public protocol GitHubRepositoryIdentityResolverProtocol: AnyObject, Sendable {
  func resolveIdentities(at projectPath: String, expectedHost: String) async -> Set<
    GitHubRepositoryIdentity
  >
  func resolveIdentity(at projectPath: String) async -> GitHubRepositoryIdentity?
  func resolveIdentity(at projectPath: String, expectedHost: String) async
    -> GitHubRepositoryIdentity?
}

extension GitHubRepositoryIdentityResolverProtocol {
  public func resolveIdentities(at projectPath: String, expectedHost: String) async -> Set<
    GitHubRepositoryIdentity
  > {
    guard let identity = await resolveIdentity(at: projectPath, expectedHost: expectedHost) else {
      return []
    }
    return [identity]
  }

  public func resolveIdentity(at projectPath: String, expectedHost: String) async
    -> GitHubRepositoryIdentity?
  {
    let identity = await resolveIdentity(at: projectPath)
    return identity?.host.caseInsensitiveCompare(expectedHost) == .orderedSame ? identity : nil
  }
}

public actor GitHubRepositoryIdentityResolver: GitHubRepositoryIdentityResolverProtocol {
  private var cache: [String: GitHubRepositoryIdentity] = [:]
  private var attemptedPaths: Set<String> = []

  public init() {}

  public func resolveIdentity(at projectPath: String) async -> GitHubRepositoryIdentity? {
    let normalizedPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    if attemptedPaths.contains(normalizedPath) {
      return cache[normalizedPath]
    }

    attemptedPaths.insert(normalizedPath)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      return nil
    }
    guard let output = Self.gitRemoteOutput(at: normalizedPath) else { return nil }

    let candidates = output
      .split(whereSeparator: \.isNewline)
      .compactMap(Self.remoteCandidate(from:))

    let identity = candidates
      .first(where: { $0.name == "origin" })?.identity
      ?? candidates.first?.identity

    if let identity {
      cache[normalizedPath] = identity
    }
    return identity
  }

  public func resolveIdentity(at projectPath: String, expectedHost: String) async
    -> GitHubRepositoryIdentity?
  {
    // Launches need fresh remote evidence, even if the checkout was repointed.
    guard let output = Self.gitRemoteOutput(at: projectPath) else { return nil }
    let candidates = output.split(whereSeparator: \.isNewline).compactMap {
      line -> (String, GitHubRepositoryIdentity)? in
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2,
        let identity = GitHubRepositoryIdentity(
          remoteURL: String(fields[1]), expectedHost: expectedHost)
      else { return nil }
      return (String(fields[0]), identity)
    }
    return candidates.first(where: { $0.0 == "origin" })?.1 ?? candidates.first?.1
  }

  public func resolveIdentities(at projectPath: String, expectedHost: String) async -> Set<
    GitHubRepositoryIdentity
  > {
    // Read fresh remotes so launches and session links reflect repository changes.
    guard let output = Self.gitRemoteOutput(at: projectPath) else { return [] }
    return Set(
      output.split(whereSeparator: \.isNewline).compactMap { line in
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }
        return GitHubRepositoryIdentity(remoteURL: String(fields[1]), expectedHost: expectedHost)
      })
  }

  private nonisolated static func gitRemoteOutput(at projectPath: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", projectPath, "remote", "-v"]

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return nil
    }

    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private nonisolated static func remoteCandidate(
    from line: Substring
  ) -> (name: String, identity: GitHubRepositoryIdentity)? {
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 2,
          let identity = GitHubRepositoryIdentity(remoteURL: String(fields[1])) else {
      return nil
    }
    return (String(fields[0]), identity)
  }
}
