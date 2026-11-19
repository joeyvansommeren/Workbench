import Testing

/// Waits for an observed completion instead of assuming a background task's duration.
struct AsyncTestCompletion: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    stream = channel.stream
    continuation = channel.continuation
  }

  func signal() {
    continuation.yield(())
    continuation.finish()
  }

  func wait() async throws {
    defer { continuation.finish() }
    var iterator = stream.makeAsyncIterator()
    let didComplete = await iterator.next()
    try #require(didComplete != nil, "Expected asynchronous operation to complete")
  }
}
