import Foundation
import Testing

/// A test clock whose sleep requests can be acknowledged before time advances.
@MainActor
final class ManualTaskClock {
  struct SleepRequest: Equatable, Sendable {
    let id: Int
    let duration: Duration
  }

  private struct Sleeper {
    let deadline: ContinuousClock.Instant
    let continuation: CheckedContinuation<Void, Error>
  }

  private struct Observer {
    let duration: Duration
    let afterID: Int
    let id: UUID
    let continuation: CheckedContinuation<SleepRequest, Error>
  }

  private var instant = ContinuousClock.now
  private var nextID = 1
  private var sleepers: [Int: Sleeper] = [:]
  private var requests: [SleepRequest] = []
  private var observers: [Observer] = []
  private var completions: [Int: TestCallbackReceipt] = [:]
  private var isClosed = false

  var now: ContinuousClock.Instant { instant }
  var pendingSleepCount: Int { sleepers.count }
  var pendingObserverCount: Int { observers.count }

  func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    guard !isClosed else { throw CancellationError() }
    let id = nextID
    nextID += 1
    let completion = TestCallbackReceipt()
    completions[id] = completion
    defer { completion.record() }
    let deadline = instant.advanced(by: duration)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
        let request = SleepRequest(id: id, duration: duration)
        requests.append(request)
        let ready = observers.filter { $0.duration == duration && id > $0.afterID }
        observers.removeAll { $0.duration == duration && id > $0.afterID }
        for observer in ready {
          observer.continuation.resume(returning: request)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelSleep(id: id)
      }
    }
  }

  /// Waits for an actual suspension, including one registered before this call.
  func nextSleep(
    for duration: Duration, after id: Int = 0, onRegistered: (@MainActor () -> Void)? = nil
  ) async throws -> SleepRequest {
    try Task.checkCancellation()
    guard !isClosed else { throw CancellationError() }
    if let request = requests.first(where: { $0.duration == duration && $0.id > id }) {
      return request
    }
    let observerID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled, !isClosed else {
          continuation.resume(throwing: CancellationError())
          return
        }
        observers.append(Observer(duration: duration, afterID: id, id: observerID, continuation: continuation))
        onRegistered?()
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelObserver(id: observerID)
      }
    }
  }

  func waitForCompletion(of request: SleepRequest) async throws {
    guard let completion = completions[request.id] else {
      preconditionFailure("Unknown sleep request")
    }
    try await completion.wait()
  }

  func advance(by duration: Duration) {
    precondition(duration >= .zero)
    instant = instant.advanced(by: duration)
    let due = sleepers.filter { $0.value.deadline <= instant }.map(\.key).sorted()
    for id in due {
      sleepers.removeValue(forKey: id)?.continuation.resume()
    }
  }

  /// Releases grace-clear timers after a progress test releases its coordinator.
  func close() {
    isClosed = true
    let pending = Array(sleepers.values)
    let pendingObservers = observers
    sleepers.removeAll()
    observers.removeAll()
    for sleeper in pending {
      sleeper.continuation.resume(throwing: CancellationError())
    }
    for observer in pendingObservers {
      observer.continuation.resume(throwing: CancellationError())
    }
  }

  private func cancelObserver(id: UUID) {
    guard let index = observers.firstIndex(where: { $0.id == id }) else { return }
    observers.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  private func cancelSleep(id: Int) {
    sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
  }
}

/// Records callback delivery without imposing a wall-clock scheduling deadline.
final class TestCallbackReceipt: @unchecked Sendable {
  private struct Waiter {
    let expectedCount: Int
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var count = 0
  private var waiters: [UUID: Waiter] = [:]

  var pendingWaiterCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return waiters.count
  }

  var hasRecorded: Bool {
    lock.lock()
    defer { lock.unlock() }
    return count > 0
  }

  func record() {
    lock.lock()
    count += 1
    let readyIDs = waiters.filter { $0.value.expectedCount <= count }.map(\.key)
    let ready = readyIDs.compactMap { waiters.removeValue(forKey: $0) }
    lock.unlock()
    for waiter in ready { waiter.continuation.resume() }
  }

  func wait(for expectedCount: Int = 1, onRegistered: (@Sendable () -> Void)? = nil) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        if Task.isCancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
        } else if count >= expectedCount {
          lock.unlock()
          continuation.resume()
        } else {
          waiters[id] = Waiter(expectedCount: expectedCount, continuation: continuation)
          lock.unlock()
          onRegistered?()
        }
      }
    } onCancel: {
      self.cancelWaiter(id: id)
    }
  }

  private func cancelWaiter(id: UUID) {
    lock.lock()
    let waiter = waiters.removeValue(forKey: id)
    lock.unlock()
    waiter?.continuation.resume(throwing: CancellationError())
  }
}

@MainActor
@Suite("Manual task clock cancellation")
struct ManualTaskClockTests {
  @Test("Cancellation before a task starts does not register a sleep")
  func cancellationBeforeRegistration() async {
    let clock = ManualTaskClock()
    let task = Task { try await clock.sleep(for: .seconds(1)) }
    task.cancel()
    do {
      try await task.value
      Issue.record("A canceled task must throw")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(clock.pendingSleepCount == 0)
  }

  @Test("Cancellation while suspended removes and resumes the sleep once")
  func cancellationWhileSuspended() async throws {
    let clock = ManualTaskClock()
    let task = Task { try await clock.sleep(for: .seconds(1)) }
    _ = try await clock.nextSleep(for: .seconds(1))
    task.cancel()
    do {
      try await task.value
      Issue.record("A canceled sleep must throw")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(clock.pendingSleepCount == 0)
    clock.advance(by: .seconds(2))
    #expect(clock.pendingSleepCount == 0)
  }

  @Test("Cancellation after an advance cannot resume a completed sleep twice")
  func cancellationAfterAdvance() async throws {
    let clock = ManualTaskClock()
    let task = Task { try await clock.sleep(for: .seconds(1)) }
    _ = try await clock.nextSleep(for: .seconds(1))
    clock.advance(by: .seconds(1))
    try await task.value
    task.cancel()
    clock.advance(by: .seconds(1))
    #expect(clock.pendingSleepCount == 0)
  }
}
