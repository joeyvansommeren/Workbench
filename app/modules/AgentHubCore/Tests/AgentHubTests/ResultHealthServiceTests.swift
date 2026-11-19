import Foundation
import Network
import Testing

@testable import AgentHubCore

private final class HealthURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var requests: [URLRequest] = []

  static func reset() {
    lock.lock()
    requests = []
    lock.unlock()
  }

  static func recordedRequests() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.requests.append(request)
    Self.lock.unlock()
    guard let url = request.url else { return }
    let status: Int
    switch (url.path, request.httpMethod) {
    case ("/get-only", "HEAD"), ("/fallback-redirect", "HEAD"), ("/slash-fallback", "HEAD"):
      status = 405
    case ("/not-implemented", "HEAD"): status = 501
    case ("/missing", _): status = 404
    default: status = 200
    }
    let responseURL = responseURL(for: url)
    let response = HTTPURLResponse(
      url: responseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if request.httpMethod != "HEAD" {
      client?.urlProtocol(self, didLoad: Data([0]))
    }
    client?.urlProtocolDidFinishLoading(self)
  }
  private func responseURL(for url: URL) -> URL {
    let changedDestination =
      url.path == "/redirected"
      || (url.path == "/fallback-redirect" && request.httpMethod == "GET")
    let responseURL: URL
    switch url.absoluteString {
    case "http://localhost:3000/docs": responseURL = URL(string: "http://localhost:3000/docs/")!
    case "http://localhost:3000/guide/": responseURL = URL(string: "http://localhost:3000/guide")!
    case "http://localhost:3000/slash-fallback" where request.httpMethod == "GET":
      responseURL = URL(string: "http://localhost:3000/slash-fallback/")!
    case "http://localhost:3000/credentials":
      responseURL = URL(string: "http://fixture@localhost:3000/credentials/")!
    case "http://localhost:3000/tabs?tab=a":
      responseURL = URL(string: "http://localhost:3000/tabs/?tab=b")!
    default: responseURL = changedDestination ? URL(string: "http://localhost:3000/other")! : url
    }
    return responseURL
  }

  override func stopLoading() {}
}

@Suite("Result health", .serialized)
struct ResultHealthServiceTests {
  @Test func streamingResponseReturnsWithoutWaitingForBody() async throws {
    for (contentType, byteCount) in [("text/event-stream", 1), ("text/plain", 512)] {
      let server = try HealthHTTPServer(
        mode: .stream(contentType: contentType, byteCount: byteCount))
      defer { server.stop() }
      let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/result?view=edit#dialog"))
      #expect(await ResultHealthService().isReachable(url))
      let requests = server.recordedRequests()
      try #require(requests.count == 2)
      #expect(requests[0].hasPrefix("HEAD /result?view=edit HTTP/1.1"))
      #expect(requests[1].hasPrefix("GET /result?view=edit HTTP/1.1"))
      #expect(requests[1].lowercased().contains("range: bytes=0-0"))
    }
  }

  @Test func sparseTrickleStopsAtResourceDeadline() async throws {
    let server = try HealthHTTPServer(mode: .trickle)
    defer { server.stop() }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/slow"))
    // CFNetwork waits for more plain text before delivering its response.
    // The stream ends after six seconds, but the probe's total limit is four.
    #expect(!(await ResultHealthService().isReachable(url)))
    #expect(server.recordedRequests().count == 2)
  }

  @Test func callerCancellationClosesPendingProbe() async throws {
    let server = try HealthHTTPServer(mode: .hold)
    defer { server.stop() }
    let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/pending"))
    let task = Task { await ResultHealthService().isReachable(url) }
    guard await server.waitForRequest() else {
      task.cancel()
      Issue.record("The test server did not receive the request")
      return
    }
    task.cancel()
    #expect(!(await task.value))
    #expect(await server.waitForDisconnect())
  }

  @Test func headFallbackUsesExactDestination() async throws {
    HealthURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HealthURLProtocol.self]
    let service = ResultHealthService(configuration: configuration)
    let getOnly = try #require(URL(string: "http://localhost:3000/get-only?state=edit#dialog"))
    #expect(await service.isReachable(getOnly))
    let requests = HealthURLProtocol.recordedRequests()
    #expect(requests.map(\.httpMethod) == ["HEAD", "GET"])
    #expect(
      requests.allSatisfy { $0.url?.absoluteString == "http://localhost:3000/get-only?state=edit" })
    #expect(requests.last?.value(forHTTPHeaderField: "Range") == "bytes=0-0")

    #expect(await service.isReachable(URL(string: "http://localhost:3000/not-implemented")!))
    #expect(!(await service.isReachable(URL(string: "http://localhost:3000/missing")!)))
    #expect(!(await service.isReachable(URL(string: "http://localhost:3000/redirected")!)))
    #expect(!(await service.isReachable(URL(string: "http://localhost:3000/fallback-redirect")!)))
    let allRequests = HealthURLProtocol.recordedRequests()
    #expect(
      allRequests.map(\.httpMethod) == [
        "HEAD", "GET", "HEAD", "GET", "HEAD", "HEAD", "HEAD", "GET",
      ])
  }

  @Test func trailingSlashRedirectKeepsTheRequestedRoute() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HealthURLProtocol.self]
    let service = ResultHealthService(configuration: configuration)
    #expect(await service.isReachable(URL(string: "http://localhost:3000/docs")!))
    #expect(await service.isReachable(URL(string: "http://localhost:3000/guide/")!))
    #expect(await service.isReachable(URL(string: "http://localhost:3000/slash-fallback")!))
  }

  @Test func trailingSlashRedirectWithAChangedQueryIsAnotherRoute() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HealthURLProtocol.self]
    let service = ResultHealthService(configuration: configuration)
    #expect(!(await service.isReachable(URL(string: "http://localhost:3000/tabs?tab=a")!)))
  }

  @Test func redirectWithCredentialsIsAnotherRoute() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HealthURLProtocol.self]
    let service = ResultHealthService(configuration: configuration)
    #expect(!(await service.isReachable(URL(string: "http://localhost:3000/credentials")!)))
  }
}

private final class HealthHTTPServer: @unchecked Sendable {
  enum Mode {
    case stream(contentType: String, byteCount: Int)
    case trickle
    case hold
  }
  private let listener: NWListener
  private let queue = DispatchQueue(label: "ResultHealthHTTPServer")
  private let mode: Mode
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private var requests: [String] = []
  private let requestReceived = DispatchSemaphore(value: 0)
  private let disconnected = DispatchSemaphore(value: 0)
  private(set) var port: UInt16 = 0

  init(mode: Mode) throws {
    self.mode = mode
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
      if case .failed = state { ready.signal() }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port?.rawValue,
      port != 0
    else {
      listener.cancel()
      throw CocoaError(.fileReadUnknown)
    }
    self.port = port
  }

  func recordedRequests() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  func waitForRequest() async -> Bool { await wait(requestReceived) }
  func waitForDisconnect() async -> Bool { await wait(disconnected) }

  private func wait(_ signal: DispatchSemaphore) async -> Bool {
    await Task.detached { signal.wait(timeout: .now() + 5) == .success }.value
  }

  func stop() {
    listener.cancel()
    lock.lock()
    let connections = self.connections
    self.connections.removeAll()
    lock.unlock()
    for connection in connections { connection.cancel() }
  }

  private func accept(_ connection: NWConnection) {
    lock.lock()
    connections.append(connection)
    lock.unlock()
    connection.start(queue: queue)
    receiveRequest(connection, data: Data())
  }

  private func receiveRequest(_ connection: NWConnection, data: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] bytes, _, _, _ in
      guard let self else { return }
      var data = data
      data.append(bytes ?? Data())
      guard let request = String(data: data, encoding: .utf8) else { return }
      guard request.contains("\r\n\r\n") else {
        self.receiveRequest(connection, data: data)
        return
      }
      self.lock.lock()
      self.requests.append(request)
      self.lock.unlock()
      self.requestReceived.signal()
      if case .hold = self.mode {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
          [weak self] _, _, complete, error in
          if complete || error != nil { self?.disconnected.signal() }
        }
      } else if request.hasPrefix("HEAD ") {
        let response = Data(
          "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(
          content: response, completion: .contentProcessed { _ in connection.cancel() })
      } else {
        switch self.mode {
        case .stream(let contentType, let byteCount):
          let headers =
            "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\n\r\n"
          let chunk =
            "\(String(byteCount, radix: 16))\r\n" + String(repeating: "x", count: byteCount)
            + "\r\n"
          connection.send(
            content: Data((headers + chunk).utf8), completion: .contentProcessed { _ in })
        case .trickle:
          let headers =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n"
          connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
          self.sendTrickle(connection, remaining: 20)
        case .hold:
          break
        }
      }
    }
  }

  private func sendTrickle(_ connection: NWConnection, remaining: Int) {
    let chunk = remaining == 0 ? "0\r\n\r\n" : "1\r\nx\r\n"
    connection.send(
      content: Data(chunk.utf8),
      completion: .contentProcessed { [weak self] error in
        guard error == nil, remaining > 0, let self else { return }
        self.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
          self?.sendTrickle(connection, remaining: remaining - 1)
        }
      })
  }
}
