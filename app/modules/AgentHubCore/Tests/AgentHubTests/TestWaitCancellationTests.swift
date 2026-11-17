import Foundation
import Testing

@MainActor
@Suite("Test wait cancellation")
struct TestWaitCancellationTests {
  @Test("A cancelled receipt waiter does not register")
  func receiptCancelledBeforeRegistration() async {
    let receipt = TestCallbackReceipt()
    let task = Task { try await receipt.wait() }
    task.cancel()
    do {
      try await task.value
      Issue.record("A cancelled wait must throw")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(!receipt.hasRecorded)
  }

  @Test("A registered receipt waiter resumes when cancelled")
  func receiptCancelledAfterRegistration() async {
    let receipt = TestCallbackReceipt()
    let (registered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { signal.finish() }
    let task = Task { try await receipt.wait(onRegistered: { signal.yield(()) }) }
    var iterator = registered.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()
    do {
      try await task.value
      Issue.record("A cancelled wait must throw")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(!receipt.hasRecorded)
    receipt.record()
    #expect(receipt.hasRecorded)
  }

  @Test("A recorded receipt completes before later cancellation")
  func receiptRecordBeforeCancel() async throws {
    let receipt = TestCallbackReceipt()
    let (registered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { signal.finish() }
    let task = Task { try await receipt.wait(onRegistered: { signal.yield(()) }) }
    var iterator = registered.makeAsyncIterator()
    _ = await iterator.next()
    #expect(receipt.pendingWaiterCount == 1)
    receipt.record()
    try await task.value
    task.cancel()
    #expect(receipt.pendingWaiterCount == 0)
    #expect(receipt.hasRecorded)
  }

  @Test("Cancelling a receipt waiter does not record an event")
  func receiptCancelBeforeRecord() async {
    let receipt = TestCallbackReceipt()
    let (registered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { signal.finish() }
    let task = Task { try await receipt.wait(onRegistered: { signal.yield(()) }) }
    var iterator = registered.makeAsyncIterator()
    _ = await iterator.next()
    #expect(receipt.pendingWaiterCount == 1)
    task.cancel()
    do {
      try await task.value
      Issue.record("A cancelled wait must throw") } catch { #expect(error is CancellationError)
    }
    #expect(receipt.pendingWaiterCount == 0)
    #expect(!receipt.hasRecorded)
    receipt.record()
    #expect(receipt.hasRecorded)
    #expect(receipt.pendingWaiterCount == 0)
  }

  @Test("Record and cancellation each resume a waiter at most once")
  func receiptRecordCancellationRace() async {
    for _ in 0..<100 {
      let receipt = TestCallbackReceipt()
      let (registered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let task = Task { try await receipt.wait(onRegistered: { signal.yield(()) }) }
      var iterator = registered.makeAsyncIterator()
      _ = await iterator.next()
      await withTaskGroup(of: Void.self) { group in
        group.addTask { receipt.record() }
        group.addTask { task.cancel() }
      }
      do { try await task.value } catch { #expect(error is CancellationError) }
      #expect(receipt.hasRecorded)
      signal.finish()
    }
  }

  @Test("A cancelled clock observation does not register")
  func observerCancelledBeforeRegistration() async {
    let clock = ManualTaskClock()
    defer { clock.close() }
    let task = Task { try await clock.nextSleep(for: .seconds(1)) }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("A cancelled observer must throw") } catch { #expect(error is CancellationError)
    }
  }

  @Test("Advance, cancellation and close cannot resume a sleep twice")
  func advanceCancelClose() async throws {
    for _ in 0..<100 {
      let clock = ManualTaskClock()
      let task = Task { try await clock.sleep(for: .seconds(1)) }
      let request = try await clock.nextSleep(for: .seconds(1))
      task.cancel()
      clock.advance(by: .seconds(1))
      clock.close()
      do { try await task.value } catch { #expect(error is CancellationError) }
      try await clock.waitForCompletion(of: request)
      #expect(clock.pendingSleepCount == 0)
    }
  }

  @Test("Closing a clock rejects an observer and later observations")
  func closeDrainsObservers() async {
    let clock = ManualTaskClock()
    let (registered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { signal.finish() }
    let task = Task { try await clock.nextSleep(for: .seconds(1), onRegistered: { signal.yield(()) }) }
    var iterator = registered.makeAsyncIterator()
    _ = await iterator.next()
    clock.close()
    do {
      _ = try await task.value
      Issue.record("A closed clock must throw") } catch { #expect(error is CancellationError)
    }
    do {
      _ = try await clock.nextSleep(for: .seconds(1))
      Issue.record("A closed clock must reject new observers") } catch { #expect(error is CancellationError)
    }
  }

  @Test("Cancellation removes a registered clock observer")
  func cancelObserver() async {
    let clock = ManualTaskClock()
    defer { clock.close() }
    let (registered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { signal.finish() }
    let task = Task { try await clock.nextSleep(for: .seconds(1), onRegistered: { signal.yield(()) }) }
    var iterator = registered.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("A cancelled observer must throw") } catch { #expect(error is CancellationError)
    }
  }

  @Test("Closing an observer before cancellation throws and removes it")
  func observerCloseBeforeCancel() async {
    let clock = ManualTaskClock()
    let (registered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { signal.finish() }
    let task = Task { try await clock.nextSleep(for: .seconds(1), onRegistered: { signal.yield(()) }) }
    var iterator = registered.makeAsyncIterator()
    _ = await iterator.next()
    #expect(clock.pendingObserverCount == 1)
    clock.close()
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Closing a missing request must throw") } catch { #expect(error is CancellationError)
    }
    #expect(clock.pendingObserverCount == 0)
  }

  @Test("Cancelling an observer before close throws and removes it")
  func observerCancelBeforeClose() async {
    let clock = ManualTaskClock()
    let (registered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { signal.finish() }
    let task = Task { try await clock.nextSleep(for: .seconds(1), onRegistered: { signal.yield(()) }) }
    var iterator = registered.makeAsyncIterator()
    _ = await iterator.next()
    #expect(clock.pendingObserverCount == 1)
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("A cancelled observer must throw") } catch { #expect(error is CancellationError)
    }
    #expect(clock.pendingObserverCount == 0)
    clock.close()
    #expect(clock.pendingObserverCount == 0)
    do {
      _ = try await clock.nextSleep(for: .seconds(1))
      Issue.record("A closed clock must throw") } catch { #expect(error is CancellationError)
    }
  }

  @Test("Clock close cancels a registered sleep without recording time")
  func closeDrainsSleep() async throws {
    let clock = ManualTaskClock()
    let task = Task { try await clock.sleep(for: .seconds(1)) }
    let request = try await clock.nextSleep(for: .seconds(1))
    clock.close()
    do {
      try await task.value
      Issue.record("A closed clock must cancel the sleep") } catch { #expect(error is CancellationError)
    }
    try await clock.waitForCompletion(of: request)
    #expect(clock.pendingSleepCount == 0)
  }
}
