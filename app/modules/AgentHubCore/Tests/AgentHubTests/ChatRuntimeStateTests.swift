import Foundation
import Testing

@testable import AgentHubCore

private func user(_ text: String, id: String = UUID().uuidString, at date: Date? = nil) -> ChatTranscriptItem {
  ChatTranscriptItem(id: id, kind: .user(text), timestamp: date)
}

private func assistant(_ text: String) -> ChatTranscriptItem {
  ChatTranscriptItem(id: UUID().uuidString, kind: .assistant(text), timestamp: nil)
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite("Chat transcript runtime")
struct ChatTranscriptRuntimeTests {
  @Test("Enqueue, dequeue (oldest first), and remove keep the queue truthful; internal entries stay hidden")
  func queueOperations() {
    var runtime = ChatTranscriptRuntime()
    runtime.apply(.enqueue(text: "<task-notification>\n<task-id>x</task-id>", at: t0, isInternal: true))
    runtime.apply(.enqueue(text: "first", at: t0, isInternal: false))
    runtime.apply(.enqueue(text: "second", at: t0, isInternal: false))
    #expect(runtime.visibleQueue.map(\.text) == ["first", "second"])
    #expect(runtime.queue.count == 3)

    runtime.apply(.dequeue)  // pops the internal entry, not the user's
    #expect(runtime.visibleQueue.map(\.text) == ["first", "second"])
    runtime.apply(.remove(text: "second"))
    #expect(runtime.visibleQueue.map(\.text) == ["first"])
    runtime.apply(.dequeue)
    #expect(runtime.visibleQueue.isEmpty)
    runtime.apply(.dequeue)  // nothing left: no crash, no change
    #expect(runtime.queue.isEmpty)
  }

  @Test("Queue and background tasks are capped")
  func caps() {
    var runtime = ChatTranscriptRuntime()
    for index in 0..<(ChatTranscriptRuntime.cap + 5) {
      runtime.apply(.enqueue(text: "m\(index)", at: nil, isInternal: false))
      runtime.apply(.backgroundTaskStarted(id: "t\(index)", at: nil))
    }
    #expect(runtime.queue.count == ChatTranscriptRuntime.cap)
    #expect(runtime.queue.first?.text == "m5")
    #expect(runtime.unfinishedBackgroundTasks.count == ChatTranscriptRuntime.cap)
  }

  @Test("A background task is unfinished until its notification; a finish without a start is ignored")
  func backgroundTasks() {
    var runtime = ChatTranscriptRuntime()
    runtime.apply(.backgroundTaskFinished(id: "ghost"))
    runtime.apply(.backgroundTaskStarted(id: "a1", at: t0))
    runtime.apply(.backgroundTaskStarted(id: "b2", at: nil))
    runtime.apply(.backgroundTaskStarted(id: "a1", at: nil))  // duplicate start counts once
    runtime.apply(.backgroundTaskFinished(id: "a1"))
    #expect(runtime.unfinishedBackgroundTasks.map(\.id) == ["b2"])
    #expect(
      ChatRuntimeText.backgroundTaskLine(runtime.unfinishedBackgroundTasks)
        == "1 background task started, no completion seen yet · b2")
    #expect(ChatRuntimeText.backgroundTaskLine([]) == nil)
  }

  @Test("The compaction line carries only the recorded facts")
  func compactionLine() {
    #expect(
      ChatRuntimeText.compactionLine(preTokens: 467_909, durationMs: 128_412)
        == "Context compacted · 468K tokens before · 2m 8s")
    #expect(ChatRuntimeText.compactionLine(preTokens: nil, durationMs: nil) == "Context compacted")
    #expect(ChatRuntimeText.compactionLine(preTokens: nil, durationMs: 4_000) == "Context compacted · 4s")
  }
}

@Suite("Chat outbox")
struct ChatOutboxTests {
  @Test("A send waits for evidence; an older identical message never confirms it")
  func olderTwinDoesNotConfirm() {
    var outbox = ChatOutbox()
    let old = user("yes", id: "old", at: t0.addingTimeInterval(-600))
    outbox.record("yes", items: [old, assistant("Sure?")], at: t0)
    #expect(outbox.entries.map(\.text) == ["yes"])

    outbox.reconcile(items: [old], runtime: ChatTranscriptRuntime())
    #expect(outbox.entries.count == 1)

    let fresh = user("  yes \n", id: "new", at: t0.addingTimeInterval(3))
    outbox.reconcile(items: [old, fresh], runtime: ChatTranscriptRuntime())
    #expect(outbox.entries.isEmpty)
    #expect(outbox.lastSubmission?.text == "yes")
  }

  @Test("Two identical sends need two pieces of evidence")
  func identicalSendsConsumeEvidenceOnce() {
    var outbox = ChatOutbox()
    outbox.record("go", items: [], at: t0)
    outbox.record("go", items: [], at: t0.addingTimeInterval(1))
    outbox.reconcile(items: [user("go", id: "n1", at: t0.addingTimeInterval(2))], runtime: ChatTranscriptRuntime())
    #expect(outbox.entries.count == 1)
    outbox.reconcile(items: [user("go", id: "n1", at: t0.addingTimeInterval(2))], runtime: ChatTranscriptRuntime())
    #expect(outbox.entries.count == 1)
    outbox.reconcile(
      items: [user("go", id: "n1", at: t0.addingTimeInterval(2)), user("go", id: "n2", at: t0.addingTimeInterval(5))],
      runtime: ChatTranscriptRuntime())
    #expect(outbox.entries.isEmpty)
  }

  @Test("Queue receipts hide local echoes without acknowledging the next identical send")
  func queueRecordConfirms() {
    var outbox = ChatOutbox()
    outbox.record("later", items: [], at: t0)
    outbox.record("later", items: [], at: t0)
    var runtime = ChatTranscriptRuntime()
    runtime.apply(.enqueue(text: "later", at: t0.addingTimeInterval(1), isInternal: false))
    outbox.reconcile(items: [], runtime: runtime)
    #expect(outbox.entries.count == 2)
    #expect(outbox.entriesAwaitingConfirmation(runtime: runtime).count == 1)
    outbox.reconcile(items: [], runtime: runtime)
    #expect(outbox.entriesAwaitingConfirmation(runtime: runtime).count == 1)

    runtime.apply(.dequeue)
    let delivered = [user("later", id: "one", at: t0.addingTimeInterval(2))]
    outbox.reconcile(items: delivered, runtime: runtime)
    #expect(outbox.entries.count == 1)
    outbox.reconcile(items: delivered, runtime: runtime)
    #expect(outbox.entries.count == 1)
  }

  @Test("An existing queue entry cannot hide a later identical local send")
  func existingQueueDoesNotConfirmNewSend() {
    var runtime = ChatTranscriptRuntime()
    runtime.apply(.enqueue(text: "later", at: t0, isInternal: false))
    var outbox = ChatOutbox()
    outbox.record("later", items: [], runtime: runtime, at: t0)
    #expect(outbox.entriesAwaitingConfirmation(runtime: runtime).count == 1)
  }

  @Test("Evidence that pre-dates the send by more than the clock slack does not count; nil timestamps do")
  func timestamps() {
    var outbox = ChatOutbox()
    outbox.record("hi", items: [], at: t0)
    outbox.reconcile(items: [user("hi", id: "early", at: t0.addingTimeInterval(-60))], runtime: ChatTranscriptRuntime())
    #expect(outbox.entries.count == 1)
    outbox.reconcile(items: [user("hi", id: "untimed", at: nil)], runtime: ChatTranscriptRuntime())
    #expect(outbox.entries.isEmpty)
  }

  @Test("Blank sends are ignored; the outbox is capped; clear forgets the recall text too")
  func capsAndClear() {
    var outbox = ChatOutbox()
    outbox.record("   ", items: [], at: t0)
    #expect(outbox.entries.isEmpty)
    #expect(outbox.lastSubmission == nil)

    for index in 0..<(ChatOutbox.cap + 3) {
      outbox.record("m\(index)", items: [], at: t0)
    }
    #expect(outbox.entries.count == ChatOutbox.cap)
    #expect(outbox.entries.first?.text == "m3")

    let firstID = outbox.entries[0].id
    outbox.dismiss(firstID)
    #expect(outbox.entries.first?.text == "m4")

    outbox.clear()
    #expect(outbox.entries.isEmpty)
    #expect(outbox.lastSubmission == nil)
  }

  @Test("A reader reset that shrinks the transcript still confirms by text and identity")
  func shrunkTranscript() {
    var outbox = ChatOutbox()
    let many = (0..<700).map { user("old \($0)", id: "o\($0)", at: t0.addingTimeInterval(-100)) }
    outbox.record("go", items: many, at: t0)
    outbox.reconcile(items: [user("go", id: "fresh", at: t0.addingTimeInterval(1))], runtime: ChatTranscriptRuntime())
    #expect(outbox.entries.isEmpty)
  }
}

@Suite("Chat composer history")
struct ChatComposerHistoryTests {
  @Test("Arrow Up recalls the last local send, else the latest transcript user message, never the agent")
  func recall() {
    let items = [user("one", at: t0), assistant("reply"), user("two", at: t0.addingTimeInterval(10)), assistant("q?")]
    let local = ChatOutbox.LastSubmission(text: "local", at: t0.addingTimeInterval(20))
    #expect(ChatComposerHistory.recall(draft: "", lastSubmitted: local, items: items) == "local")
    #expect(ChatComposerHistory.recall(draft: "", lastSubmitted: nil, items: items) == "two")
    #expect(ChatComposerHistory.recall(draft: "", lastSubmitted: nil, items: [assistant("only")]) == nil)
  }

  @Test("A newer user message in the transcript (typed in the terminal) beats an older local send")
  func newerTranscriptInputWins() {
    let local = ChatOutbox.LastSubmission(text: "local", at: t0)
    let newer = [user("typed in terminal", at: t0.addingTimeInterval(30))]
    #expect(ChatComposerHistory.recall(draft: "", lastSubmitted: local, items: newer) == "typed in terminal")
    // The confirmed echo of the local send itself is not "newer input".
    let echo = [user("local", at: t0.addingTimeInterval(2))]
    #expect(ChatComposerHistory.recall(draft: "", lastSubmitted: local, items: echo) == "local")
    // Without a timestamp the transcript cannot prove it is newer.
    #expect(ChatComposerHistory.recall(draft: "", lastSubmitted: local, items: [user("untimed")]) == "local")
  }

  @Test("A draft in progress is never replaced")
  func draftWins() {
    let local = ChatOutbox.LastSubmission(text: "local", at: t0)
    #expect(ChatComposerHistory.recall(draft: "typing", lastSubmitted: local, items: [user("x")]) == nil)
  }

  @Test("Only a plain Up in an empty field without IME composition recalls")
  func keyPolicy() {
    #expect(ChatRecallKeyPolicy.shouldRecall(draftIsEmpty: true, hasModifiers: false, hasMarkedText: false))
    #expect(!ChatRecallKeyPolicy.shouldRecall(draftIsEmpty: false, hasModifiers: false, hasMarkedText: false))
    #expect(!ChatRecallKeyPolicy.shouldRecall(draftIsEmpty: true, hasModifiers: true, hasMarkedText: false))
    #expect(!ChatRecallKeyPolicy.shouldRecall(draftIsEmpty: true, hasModifiers: false, hasMarkedText: true))
  }
}

@Suite("Terminal live status detector")
struct TerminalLiveStatusDetectorTests {
  @Test("Queued CLI questions appear only with the live question footer")
  func queuedQuestions() {
    let footer = ["• Working (4m 09s)", "• Queued follow-up inputs", "  ? 1 question", "  ⇧↵ to answer", ""]
    #expect(TerminalLiveStatusDetector.status(in: footer) ==
      "Awaiting your answer · 1 question · Shift+Return in Terminal to answer")
    #expect(TerminalLiveStatusDetector.queuedQuestions(in:
      ["Queued follow-up inputs", "? 2 questions", "⇧↵ to answer"])?.contains("2 questions") == true)
    #expect(TerminalLiveStatusDetector.status(in: ["Working", "> "]) == nil)
    #expect(TerminalLiveStatusDetector.queuedQuestions(in: ["? 1 question", "⇧↵ to answer"]) == nil)
    #expect(TerminalLiveStatusDetector.queuedQuestions(in: ["Queued follow-up inputs", "? 1 question"]) == nil)
    #expect(TerminalLiveStatusDetector.queuedQuestions(in: ["Queued follow-up inputs", "? 0 questions", "⇧↵ to answer"]) == nil)
  }

  @Test("The compacting line is taken verbatim from the screen tail; nothing else is invented")
  func compacting() {
    let screen = [
      "⏺ Done with the edit.",
      "",
      "✻ Compacting context (3m 28s · ↓ 1.2k tokens)…",
      "  1 background terminal running",
      "> ",
    ]
    #expect(TerminalLiveStatusDetector.compacting(in: screen) == "Compacting context (3m 28s · ↓ 1.2k tokens)")
    #expect(TerminalLiveStatusDetector.compacting(in: ["⏺ Thinking…", "> "]) == nil)
    #expect(TerminalLiveStatusDetector.compacting(in: []) == nil)
    #expect(TerminalLiveStatusDetector.compacting(in: ["The log says Compacting context", "Compacting files now"]) == nil)
    let long = "Compacting context " + String(repeating: "x", count: 120)
    #expect(TerminalLiveStatusDetector.compacting(in: [long])?.count == 90)
  }
}
