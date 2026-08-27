import Testing

@testable import InlineKit

@Suite("Inline command registry")
struct InlineCommandRegistryTests {
  @Test("local commands have concise app-owned presentations")
  func clearPresentation() throws {
    let clear = try #require(InlineCommandRegistry.commands.first { $0.command == "clear" })
    #expect(clear.description == "Collapse history for you — nothing is deleted.")
    #expect(clear.action == .collapseHistory)

    let thread = try #require(InlineCommandRegistry.commands.first { $0.command == "thread" })
    #expect(thread.description == "Create and open a subthread.")
    #expect(thread.action == .createSubthread)
  }

  @Test("only standalone local commands resolve")
  func standaloneResolution() {
    #expect(InlineCommandRegistry.action(forStandaloneText: "/clear") == .collapseHistory)
    #expect(InlineCommandRegistry.action(forStandaloneText: "  /CLEAR\n") == .collapseHistory)
    #expect(InlineCommandRegistry.action(forStandaloneText: "/thread") == .createSubthread)
    #expect(InlineCommandRegistry.action(forStandaloneText: "\n/THREAD ") == .createSubthread)
    #expect(InlineCommandRegistry.action(forStandaloneText: "/clear now") == nil)
    #expect(InlineCommandRegistry.action(forStandaloneText: "hello /clear") == nil)
    #expect(InlineCommandRegistry.action(forStandaloneText: "/clear@bot") == nil)
  }
}
