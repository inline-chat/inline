import Foundation
import Testing

@testable import InlineUI

@Suite("Settings search")
struct SettingsSearchTests {
  private let entries: [SettingsSearchEntry<String>] = [
    SettingsSearchEntry(
      id: "launch",
      title: "Launch at Login",
      keywords: ["startup"],
      context: ["Startup", "General"]
    ),
    SettingsSearchEntry(
      id: "spelling",
      title: "Check Spelling While Typing",
      keywords: ["spellcheck"],
      context: ["Writing", "General"]
    ),
    SettingsSearchEntry(
      id: "autoDownload",
      title: "Voice Messages",
      keywords: ["audio"],
      context: ["Auto-Download", "Data & Storage"]
    ),
    SettingsSearchEntry(
      id: "theme",
      title: "Thème",
      keywords: ["colors"],
      context: ["Appearance", "Appearance"]
    ),
    SettingsSearchEntry(
      id: "messageStyle",
      title: "Message Style",
      keywords: ["bubbles"],
      context: ["Messages", "Appearance"]
    ),
  ]

  @Test("empty and whitespace queries return nothing")
  func emptyQuery() {
    #expect(SettingsSearch.results(for: "", in: entries).isEmpty)
    #expect(SettingsSearch.results(for: "   ", in: entries).isEmpty)
  }

  @Test("every token must prefix-match some word")
  func allTokensMustMatch() {
    #expect(SettingsSearch.results(for: "launch log", in: entries) == ["launch"])
    #expect(SettingsSearch.results(for: "launch xyz", in: entries).isEmpty)
    #expect(SettingsSearch.results(for: "aunch", in: entries).isEmpty)
  }

  @Test("matching ignores case, diacritics, and punctuation")
  func normalization() {
    #expect(SettingsSearch.results(for: "THEME", in: entries) == ["theme"])
    #expect(SettingsSearch.results(for: "auto-down", in: entries) == ["autoDownload"])
    #expect(SettingsSearch.results(for: "data storage", in: entries) == ["autoDownload"])
  }

  @Test("ranks title prefix over title word, keyword, and context")
  func ranking() {
    // "message" is the title prefix of Message Style and a title word of Voice Messages.
    #expect(SettingsSearch.results(for: "message", in: entries) == ["messageStyle", "autoDownload"])
    // "appearance" only matches context, so input order breaks the tie.
    #expect(SettingsSearch.results(for: "appearance", in: entries) == ["theme", "messageStyle"])
    // A keyword match outranks a context match.
    #expect(SettingsSearch.results(for: "startup", in: entries) == ["launch"])
    #expect(SettingsSearch.results(for: "spell", in: entries) == ["spelling"])
  }
}
