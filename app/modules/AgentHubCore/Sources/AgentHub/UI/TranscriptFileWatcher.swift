//
//  TranscriptFileWatcher.swift
//  AgentHub
//
//  Watches one transcript file with kqueue (DispatchSource), no polling. While
//  the file does not exist yet it watches the nearest existing ancestor
//  directory and walks down as directories and the file appear. Delete and
//  rename drop back to the directory, so an atomic rewrite is seen as well.
//  Everything runs on the main actor: one owner, no races.
//

import AppKit
import SwiftUI

/// Calls `onChange` whenever the transcript at `path` is written, created, replaced, or removed.
struct TranscriptFileWatcher: NSViewRepresentable {
  let path: String?
  let onChange: () -> Void

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.onChange = onChange
    context.coordinator.watch(path)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: TranscriptFileWatchCoordinator) {
    coordinator.stop()
  }

  func makeCoordinator() -> TranscriptFileWatchCoordinator { TranscriptFileWatchCoordinator() }
}

/// The watcher itself, separate from SwiftUI so it can be tested with a temp directory.
@MainActor
final class TranscriptFileWatchCoordinator {
  var onChange: () -> Void = {}
  private var source: DispatchSourceFileSystemObject?
  /// Bumped on every re-arm; an event from an older source is ignored.
  private var generation = 0
  private(set) var watchedPath: String?
  /// True while a directory, not the file, is being watched.
  private(set) var isWaitingForFile = false
  /// The directory currently watched while waiting; nil when the file is watched.
  private(set) var waitingDirectory: String?

  func watch(_ path: String?) {
    guard path != watchedPath || (path != nil && source == nil) else { return }
    stop()
    watchedPath = path
    guard let path else { return }
    arm(path)
  }

  func stop() {
    cancelSource()
    generation += 1
    watchedPath = nil
    isWaitingForFile = false
    waitingDirectory = nil
  }

  // MARK: - Arming

  /// File first; otherwise the nearest existing ancestor. One source at a time.
  private func arm(_ path: String) {
    if armFile(path) { return }
    armNearestDirectory(of: path)
  }

  private func cancelSource() {
    source?.cancel()
    source = nil
  }

  /// Opens the file for events; false when it does not exist (yet).
  private func armFile(_ path: String) -> Bool {
    let descriptor = open(path, O_EVTONLY)
    guard descriptor >= 0 else { return false }
    cancelSource()
    generation += 1
    let generation = generation
    isWaitingForFile = false
    waitingDirectory = nil
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.generation == generation, self.watchedPath == path,
          let current = self.source
        else { return }
        let event = current.data
        if event.contains(.delete) || event.contains(.rename) {
          // The inode we held is gone (replaced or removed); follow the path again.
          self.arm(path)
        }
        self.onChange()
      }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    self.source = source
    return true
  }

  /// Watches the closest ancestor that exists. On any write in it, re-check:
  /// the file may now exist, or a nearer ancestor may have been created.
  private func armNearestDirectory(of path: String) {
    var directory = (path as NSString).deletingLastPathComponent
    var descriptor = open(directory, O_EVTONLY)
    while descriptor < 0, directory != "/", !directory.isEmpty {
      directory = (directory as NSString).deletingLastPathComponent
      descriptor = open(directory, O_EVTONLY)
    }
    guard descriptor >= 0 else {
      // Nothing to attach to. Leave no source; the UI offers a manual retry.
      cancelSource()
      generation += 1
      isWaitingForFile = true
      waitingDirectory = nil
      return
    }
    cancelSource()
    generation += 1
    let generation = generation
    isWaitingForFile = true
    waitingDirectory = directory
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.generation == generation, self.watchedPath == path else { return }
        if let event = self.source?.data, event.contains(.delete) || event.contains(.rename) {
          self.arm(path)
        } else {
          self.descend(path)
        }
      }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    self.source = source
    // The file (or a nearer directory) may have appeared between the failed
    // open and this subscription. Check once now so nothing is missed.
    descend(path)
  }

  /// Switch to the file if it exists, else to a nearer directory if one appeared.
  private func descend(_ path: String) {
    if armFile(path) {
      let generation = generation
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        self.onChange()
      }
      return
    }
    let nearest = Self.nearestExistingDirectory(of: path)
    if nearest != waitingDirectory {
      armNearestDirectory(of: path)
    }
  }

  static func nearestExistingDirectory(of path: String) -> String? {
    var directory = (path as NSString).deletingLastPathComponent
    var isDirectory: ObjCBool = false
    while !directory.isEmpty {
      if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
        let descriptor = open(directory, O_EVTONLY)
        if descriptor >= 0 {
          close(descriptor)
          return directory
        }
      }
      if directory == "/" { return nil }
      directory = (directory as NSString).deletingLastPathComponent
    }
    return nil
  }
}
