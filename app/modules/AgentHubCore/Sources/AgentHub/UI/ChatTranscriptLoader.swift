//
//  ChatTranscriptLoader.swift
//  AgentHub
//
//  Owns the chat's load lifecycle: one in-flight load per view, cancelled and
//  superseded when the path changes, so a slow transcript can never show up
//  under another session's name.
//

import Foundation
import Observation

@MainActor
@Observable
final class ChatTranscriptLoader {
  enum Phase: Equatable {
    /// No path yet: the session has not written its first message.
    case noTranscript
    case loading
    /// The path is known but the file is not on disk (yet).
    case missing
    case ready
  }

  private(set) var items: [ChatTranscriptItem] = []
  /// Queue and background-task facts for the whole file (not window-capped).
  private(set) var runtime = ChatTranscriptRuntime()
  private(set) var phase: Phase = .noTranscript
  private(set) var path: String?

  private let reader: any ChatTranscriptReading
  private var task: Task<Void, Never>?
  private var generation = 0

  init(reader: any ChatTranscriptReading) {
    self.reader = reader
  }

  /// Starts (or restarts) following `path`. A different path clears the items at
  /// once; the same path reloads in place and keeps what is shown until the new
  /// items arrive.
  func load(path newPath: String?, provider: SessionProviderKind) {
    task?.cancel()
    generation += 1
    let generation = generation
    if newPath != path {
      path = newPath
      items = []
      runtime = ChatTranscriptRuntime()
      phase = newPath == nil ? .noTranscript : .loading
    }
    guard let newPath else {
      task = nil
      return
    }
    if phase == .noTranscript { phase = .loading }
    task = Task { [reader] in
      let result = await reader.load(at: newPath, provider: provider)
      guard !Task.isCancelled, generation == self.generation else { return }
      apply(result, for: newPath)
    }
  }

  private func apply(_ result: ChatTranscriptLoad, for loadedPath: String) {
    guard loadedPath == path else { return }
    switch result {
    case .missing:
      items = []
      runtime = ChatTranscriptRuntime()
      phase = .missing
    case .loaded(let latest, let latestRuntime):
      if latest != items { items = latest }
      if latestRuntime != runtime { runtime = latestRuntime }
      phase = .ready
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}
