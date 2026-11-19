import Foundation
import Testing

@Suite("Ephemeral defaults residue cleanup")
struct EphemeralDefaultsSuiteTests {
  @Test("Filters suite names before loading dates and preserves recent or unrelated files")
  func filtersBeforeReadingMetadata() throws {
    let fileManager = RecordingPreferencesFileManager()
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("EphemeralDefaultsSuiteTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let prefix = "test.residue"
    let ownName = "\(prefix).own"
    let own = directory.appendingPathComponent("\(ownName).plist")
    let stale = directory.appendingPathComponent("\(prefix).stale.plist")
    let recent = directory.appendingPathComponent("\(prefix).recent.plist")
    let unrelated = directory.appendingPathComponent("test.residueOther.stale.plist")
    for file in [own, stale, recent, unrelated] {
      try Data().write(to: file)
    }
    for file in [stale, unrelated] {
      try fileManager.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -1_200)], ofItemAtPath: file.path)
    }

    EphemeralDefaultsSuite.sweepResidue(
      prefix: prefix, ownSuiteName: ownName,
      preferencesDirectory: directory, fileManager: fileManager)

    #expect(fileManager.enumeratedDirectories == [directory])
    #expect(fileManager.prefetchedKeys == [])
    #expect(!fileManager.fileExists(atPath: own.path))
    #expect(!fileManager.fileExists(atPath: stale.path))
    #expect(fileManager.fileExists(atPath: recent.path))
    #expect(fileManager.fileExists(atPath: unrelated.path))
  }
}

private final class RecordingPreferencesFileManager: FileManager, @unchecked Sendable {
  var enumeratedDirectories: [URL] = []
  var prefetchedKeys: [URLResourceKey]?

  override func contentsOfDirectory(
    at url: URL,
    includingPropertiesForKeys keys: [URLResourceKey]?,
    options mask: FileManager.DirectoryEnumerationOptions = []
  ) throws -> [URL] {
    enumeratedDirectories.append(url)
    prefetchedKeys = keys
    return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
  }
}
