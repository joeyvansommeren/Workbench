import AgentHubCore
import Foundation
import GhosttySwift

enum AgentHubGhosttyAppearanceConfiguration {
  static func path(isDark: Bool) -> String? {
    Bundle.module.url(
      forResource: isDark ? "ghostty-dark" : "ghostty-light",
      withExtension: "conf"
    )?.path
  }

  /// Resolves the appearance overlay, rewriting the terminal's configured
  /// `background` (and the matching `cursor-text`) to `backdropHex` — the
  /// color the app actually paints behind the transparent surface. TUIs like
  /// Codex query the terminal background via OSC 11 and tint their highlight
  /// bands from the reply, so the configured hex must match the visible
  /// backdrop or those tints clash with it. Falls back to the bundled static
  /// overlay when no backdrop hex resolves or generation fails.
  static func path(
    isDark: Bool,
    backdropHex: String?,
    directory: URL? = nil
  ) -> String? {
    guard let bundledPath = path(isDark: isDark) else { return nil }
    guard let backdropHex = normalizedHex(backdropHex) else { return bundledPath }
    // v2: overlays gained the Cmd+1..4 unbinds; a new name skips stale cached files.
    let fileName = "appearance-v2-\(isDark ? "dark" : "light")-\(backdropHex.dropFirst()).conf"
    let targetDirectory = directory ?? defaultOverlayDirectory
    let target = targetDirectory.appendingPathComponent(fileName)
    // Content is a pure function of the file name, so an existing file is
    // always current.
    if FileManager.default.fileExists(atPath: target.path) { return target.path }
    do {
      let base = try String(contentsOfFile: bundledPath, encoding: .utf8)
      try FileManager.default.createDirectory(
        at: targetDirectory,
        withIntermediateDirectories: true
      )
      try overlayContent(base: base, backdropHex: backdropHex)
        .write(to: target, atomically: true, encoding: .utf8)
      return target.path
    } catch {
      return bundledPath
    }
  }

  /// New-shell overlay: the bundled profile rewritten so every terminal
  /// color comes from the Workbench `TerminalPalette` (background, foreground,
  /// cursor, selection and the 16 ANSI slots). The file name carries a stable
  /// hash of the colors, so a palette switch loads a new overlay.
  static func path(
    isDark: Bool,
    terminalPalette: TerminalPalette,
    directory: URL? = nil
  ) -> String? {
    guard let bundledPath = path(isDark: isDark) else { return nil }
    let fileName =
      "appearance-palette-v1-\(isDark ? "dark" : "light")-\(stableHash(terminalPalette.signature)).conf"
    let targetDirectory = directory ?? defaultOverlayDirectory
    let target = targetDirectory.appendingPathComponent(fileName)
    if FileManager.default.fileExists(atPath: target.path) { return target.path }
    do {
      let base = try String(contentsOfFile: bundledPath, encoding: .utf8)
      try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
      try overlayContent(base: base, terminalPalette: terminalPalette)
        .write(to: target, atomically: true, encoding: .utf8)
      return target.path
    } catch {
      return bundledPath
    }
  }

  /// Pure rewrite of a bundled overlay with a full terminal palette. Opacity,
  /// keybinds and comments pass through untouched.
  static func overlayContent(base: String, terminalPalette: TerminalPalette) -> String {
    let background = TerminalPalette.hex(terminalPalette.background)
    let foreground = TerminalPalette.hex(terminalPalette.foreground)
    let values: [String: String] = [
      "background": background,
      "cursor-text": background,
      "foreground": foreground,
      "cursor-color": TerminalPalette.hex(terminalPalette.cursor),
      "selection-background": TerminalPalette.hex(terminalPalette.selection),
      "selection-foreground": foreground,
    ]
    return base
      .components(separatedBy: "\n")
      .map { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equalsIndex = line.firstIndex(of: "=") else {
          return line
        }
        let key = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        if let value = values[key] { return "\(key) = \(value)" }
        guard key == "palette" else { return line }
        // `palette = N=#RRGGBB`
        let entry = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
        guard let slotEnd = entry.firstIndex(of: "="),
          let slot = Int(entry[..<slotEnd]),
          terminalPalette.ansi.indices.contains(slot)
        else { return line }
        return "palette = \(slot)=\(TerminalPalette.hex(terminalPalette.ansi[slot]))"
      }
      .joined(separator: "\n")
  }

  /// FNV-1a, stable across launches (unlike `hashValue`).
  static func stableHash(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
  }

  /// Pure rewrite of a bundled overlay: only the `background` key and the
  /// `cursor-text` key (which mirrors the background in both bundled
  /// profiles) change; opacity, contrast, palette, and comment lines pass
  /// through untouched.
  static func overlayContent(base: String, backdropHex: String) -> String {
    base
      .components(separatedBy: "\n")
      .map { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equalsIndex = line.firstIndex(of: "=") else {
          return line
        }
        let key = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        guard key == "background" || key == "cursor-text" else { return line }
        return "\(key) = \(backdropHex)"
      }
      .joined(separator: "\n")
  }

  /// Overlay used when the app backdrop adopts the user's own Ghostty
  /// background for an appearance: keep the surface transparent and let every
  /// color come from the user's config/theme (loaded underneath — see
  /// `GhosttyLayeredConfigComposer`), matching standalone Ghostty exactly,
  /// including foreground, palette, selection, cursor, and the OSC 11
  /// background reply.
  ///
  /// The adopted hex participates only in the file name: libghostty's overlay
  /// application no-ops on an unchanged path, so encoding the hex re-loads the
  /// config stack when the user's background changes. Returns nil when the
  /// overlay cannot be produced; callers fall back to the rewriting overlay.
  static func userThemePassthroughPath(
    backdropHex: String?,
    directory: URL? = nil
  ) -> String? {
    guard let backdropHex = normalizedHex(backdropHex) else { return nil }
    let fileName = "appearance-passthrough-v2-\(backdropHex.dropFirst()).conf"
    let targetDirectory = directory ?? defaultOverlayDirectory
    let target = targetDirectory.appendingPathComponent(fileName)
    if FileManager.default.fileExists(atPath: target.path) { return target.path }
    let content = """
      # Generated by AgentHub — do not edit.
      # The app paints the user's adopted Ghostty background (\(backdropHex))
      # behind a transparent surface; every color comes from the user's own
      # Ghostty config/theme so the embedded terminal matches standalone
      # Ghostty, including OSC 11 background replies.
      background-opacity = 0

      """ + hostKeybindOverrides
    do {
      try FileManager.default.createDirectory(
        at: targetDirectory,
        withIntermediateDirectories: true
      )
      try content.write(to: target, atomically: true, encoding: .utf8)
      return target.path
    } catch {
      return nil
    }
  }

  /// Frees Cmd+1..4 for AgentHub's workspace switcher: on macOS Ghostty binds
  /// Cmd+1..8 to goto_tab as non-performable, so the terminal consumes them
  /// even without Ghostty tabs. Mirrored in the bundled ghostty-*.conf files.
  static let hostKeybindOverrides = (1...4).map { digit in
    "keybind = super+digit_\(digit)=unbind\nkeybind = super+\(digit)=unbind"
  }.joined(separator: "\n") + "\n"

  static func colorScheme(isDark: Bool) -> GhosttyColorScheme {
    isDark ? .dark : .light
  }

  private static func normalizedHex(_ hex: String?) -> String? {
    guard let hex else { return nil }
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
    return "#\(digits.uppercased())"
  }

  private static var defaultOverlayDirectory: URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("AgentHubGhosttyAppearance", isDirectory: true)
  }
}
