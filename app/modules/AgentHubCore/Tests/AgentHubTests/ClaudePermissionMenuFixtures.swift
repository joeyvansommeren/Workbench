//
//  ClaudePermissionMenuFixtures.swift
//  AgentHubTests
//
//  Screen tails as Claude Code draws them. If Claude Code renumbers or
//  rewords its permission menu, update these screens from a real session: the
//  detector (`ClaudePermissionMenu`) must keep accepting the menus and keep
//  refusing everything else, or approvals fail closed for every user.
//

enum ClaudePermissionMenuFixtures {
  /// Bash prompt with the box border (Claude Code 1.x).
  static let bashBoxed = """
    ╭──────────────────────────────────────────────────────────────╮
    │ Bash command                                                 │
    │                                                              │
    │   rm -rf build                                               │
    │   Remove the build directory                                 │
    │                                                              │
    │ Do you want to proceed?                                      │
    │ ❯ 1. Yes                                                     │
    │   2. Yes, and don't ask again for rm commands in /tmp/repo   │
    │   3. No, and tell Claude what to do differently (esc)        │
    ╰──────────────────────────────────────────────────────────────╯
    """.lines

  /// Bash prompt without a border (Claude Code 2.x).
  static let bashPlain = """
    ⏺ Bash(ls -la)

     Bash command

       ls -la
       List files

     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for ls commands in /Users/me/repo
       3. No, and tell Claude what to do differently (esc)
    """.lines

  /// Edit prompt: option 2 allows all edits for the session.
  static let edit = """
     Edit file
     Sources/App/Foo.swift
     12 -    let a = 1
     12 +    let a = 2

     Do you want to make this edit to Foo.swift?
     ❯ 1. Yes
       2. Yes, allow all edits during this session (shift+tab)
       3. No, and tell Claude what to do differently (esc)
    """.lines

  /// Some prompts offer only Yes / No: "2" would be No.
  static let yesNoOnly = """
     Fetch

       https://example.com/docs

     Do you want to proceed?
     ❯ 1. Yes
       2. No, and tell Claude what to do differently (esc)
    """.lines

  /// Claude is idle at its prompt; an earlier tool ran and was answered.
  static let idlePrompt = """
    ⏺ Bash(ls)
      ⎿  Package.swift
         Sources

    ╭──────────────────────────────────────────────────────────────╮
    │ >                                                            │
    ╰──────────────────────────────────────────────────────────────╯
      ? for shortcuts
    """.lines

  /// An AskUserQuestion menu: options, but not a permission prompt.
  static let question = """
     Which database should I use?
     ❯ 1. SQLite
       2. Postgres
       3. Type something.
    """.lines
}

private extension String {
  var lines: [String] { split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
}
