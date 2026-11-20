import Foundation
@testable import InlineKit
import Testing

@Suite("Reaction chip order")
struct GroupedReactionOrderTests {
  private func reaction(_ emoji: String, by userId: Int64, at seconds: Double) -> FullReaction {
    FullReaction(reaction: Reaction(
      id: userId * 100 + Int64(seconds), messageId: 1, userId: userId, emoji: emoji,
      date: Date(timeIntervalSince1970: seconds), chatId: 1
    ))
  }

  private func message(_ reactions: [FullReaction]) -> FullMessage {
    let message = Message(
      messageId: 1, fromId: 2, date: Date(timeIntervalSince1970: 0), text: "hi",
      peerUserId: nil, peerThreadId: 1, chatId: 1
    )
    return FullMessage(senderInfo: nil, message: message, reactions: reactions, repliedToMessage: nil, attachments: [])
  }

  @Test("a chip keeps its place when someone adds its emoji later, and a new emoji joins at the end")
  func chipsKeepTheirPlaces() {
    let before = [reaction("❤️", by: 2, at: 10), reaction("👍", by: 3, at: 20), reaction("😂", by: 4, at: 30)]
    #expect(message(before).groupedReactions.map(\.emoji) == ["❤️", "👍", "😂"])

    // The reader adds ❤️ now: the ❤️ chip stays first.
    let added = before + [reaction("❤️", by: 1, at: 40)]
    #expect(message(added).groupedReactions.map(\.emoji) == ["❤️", "👍", "😂"])

    // A new emoji goes last.
    let newEmoji = added + [reaction("🔥", by: 1, at: 50)]
    #expect(message(newEmoji).groupedReactions.map(\.emoji) == ["❤️", "👍", "😂", "🔥"])
  }

  @Test("chips first used in the same second keep one order however the message is rebuilt")
  func tiesAreStable() {
    let reactions = [reaction("👍", by: 2, at: 10), reaction("❤️", by: 3, at: 10), reaction("😂", by: 4, at: 10)]
    let order = message(reactions).groupedReactions.map(\.emoji)
    #expect(message(reactions.reversed()).groupedReactions.map(\.emoji) == order)
  }
}
