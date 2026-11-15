//
//  ReviewsCopy.swift
//  AgentHub
//
//  Counted nouns for Reviews copy ("1 session", "3 sessions"), through
//  Foundation's automatic grammar agreement instead of hand-built plurals.
//

import Foundation

enum ReviewsCopy {
  /// `count` and `noun`, with the noun agreeing with the count.
  static func count(_ count: Int, _ noun: String) -> String {
    String(AttributedString(localized: "^[\(count) \(noun)](inflect: true)").characters)
  }
}
