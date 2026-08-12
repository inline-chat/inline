import Testing

@testable import InlineKit

@Suite("Inline command registry")
struct InlineCommandRegistryTests {
  @Test("clear is concise and explicitly non-destructive")
  func clearPresentation() throws {
    let command = try #require(InlineCommandRegistry.commands.first)
    #expect(command.command == "clear")
    #expect(command.description == "Collapse history for you — nothing is deleted.")
    #expect(command.action == .collapseHistory)
  }

  @Test("only standalone clear resolves locally")
  func standaloneResolution() {
    #expect(InlineCommandRegistry.action(forStandaloneText: "/clear") == .collapseHistory)
    #expect(InlineCommandRegistry.action(forStandaloneText: "  /CLEAR\n") == .collapseHistory)
    #expect(InlineCommandRegistry.action(forStandaloneText: "/clear now") == nil)
    #expect(InlineCommandRegistry.action(forStandaloneText: "hello /clear") == nil)
    #expect(InlineCommandRegistry.action(forStandaloneText: "/clear@bot") == nil)
  }
}
