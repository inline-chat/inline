import Foundation
import Testing
@testable import InlineKit

@Suite("Inline commands")
struct InlineCommandsTests {
  @Test("bot actions remain first and Inline clear explains that nothing is deleted")
  func botActionsRemainFirst() {
    let bot = PeerBotCommandSuggestion(
      command: "clear",
      description: "Bot clear",
      normalizedCommand: "clear",
      botId: 1,
      botUsername: "helper",
      botDisplayName: "Helper",
      botUserInfo: .preview,
      isAmbiguous: false
    )

    let suggestions = InlineCommands.suggestions(matching: "clear", botSuggestions: [bot])
    #expect(suggestions.count == 2)
    guard case .bot = suggestions[0] else {
      Issue.record("Expected bot command first")
      return
    }
    guard case let .inline(command) = suggestions[1] else {
      Issue.record("Expected Inline command second")
      return
    }
    #expect(command.title == "/clear")
    #expect(command.description == "Collapse history for you — nothing is deleted.")
    #expect(command.action == .transaction(.collapseHistory))
  }

  @Test("only an exact unqualified clear token resolves to Inline")
  func exactResolution() {
    #expect(InlineCommands.resolveExact(" /clear\n")?.id == .clear)
    #expect(InlineCommands.resolveExact("/clear@helper") == nil)
    #expect(InlineCommands.resolveExact("/clear later") == nil)
  }

  @Test("collapse transactions have a durable registry identifier")
  func transactionRegistry() {
    let transaction = CollapseHistoryTransaction(peerId: .thread(id: 9), maxId: 42)
    #expect(TransactionTypeRegistry.typeString(for: transaction) == "collapse_history")
  }
}
