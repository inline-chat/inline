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
    #expect(InlineCommandRegistry.action(forStandaloneText: "/rename") == .renameThread)
    #expect(InlineCommandRegistry.action(forStandaloneText: "  /RENAME\n") == .renameThread)
    #expect(InlineCommandRegistry.action(forStandaloneText: "/rename@bot") == nil)
    #expect(InlineCommandRegistry.action(forStandaloneText: "hello /rename") == nil)
    #expect(InlineCommandRegistry.suggestions(matching: "rename").first?.action == .renameThread)
    #expect(InlineCommandRegistry.action(forStandaloneText: "/clear") == .collapseHistory)
    #expect(InlineCommandRegistry.action(forStandaloneText: "  /CLEAR\n") == .collapseHistory)
    #expect(InlineCommandRegistry.action(forStandaloneText: "/thread") == .createSubthread)
    #expect(InlineCommandRegistry.action(forStandaloneText: "\n/THREAD ") == .createSubthread)
    #expect(InlineCommandRegistry.action(forStandaloneText: "/clear now") == nil)
    #expect(InlineCommandRegistry.action(forStandaloneText: "hello /clear") == nil)
    #expect(InlineCommandRegistry.action(forStandaloneText: "/clear@bot") == nil)
  }

  @Test("Compose command launch ignores reply context and blocks content modes")
  func composeLaunchState() {
    #expect(launchState(text: "") == .empty)
    #expect(launchState(text: " \n") == .empty)
    #expect(launchState(text: "draft") == .text)
    #expect(launchState(text: "", isEditing: true) == .blocked)
    #expect(launchState(text: "", isForwarding: true) == .blocked)
    #expect(launchState(text: "", hasAttachments: true) == .blocked)
    #expect(launchState(text: "", hasPendingAttachments: true) == .blocked)
    #expect(launchState(text: "", isVoiceActive: true) == .blocked)
  }

  private func launchState(
    text: String,
    isEditing: Bool = false,
    isForwarding: Bool = false,
    hasAttachments: Bool = false,
    hasPendingAttachments: Bool = false,
    isVoiceActive: Bool = false
  ) -> ComposeCommandLaunchState {
    ComposeCommandLaunchState(
      text: text,
      isEditing: isEditing,
      isForwarding: isForwarding,
      hasAttachments: hasAttachments,
      hasPendingAttachments: hasPendingAttachments,
      isVoiceActive: isVoiceActive
    )
  }
}
