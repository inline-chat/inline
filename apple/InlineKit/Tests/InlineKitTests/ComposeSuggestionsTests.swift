import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Compose suggestions")
@MainActor
struct ComposeSuggestionsTests {
  private let bot: Int64 = 7
  private let user: Int64 = 1

  private func update(_ text: String, after: Int64? = nil, from userID: Int64? = nil) -> InlineProtocol.UpdateComposeSuggestion {
    .with {
      $0.userID = userID ?? bot
      $0.peerID = .with { $0.user = .with { $0.userID = bot } }
      $0.text = text
      if let after { $0.afterMessageID = after }
    }
  }

  private var peer: InlineKit.Peer { .user(id: bot) }

  @Test("A suggestion shows until a newer message from someone else")
  func newerMessageEndsIt() {
    let store = ComposeSuggestions()
    store.apply(update(" run the tests ", after: 10))
    #expect(store.suggestion(for: peer)?.text == "run the tests")

    // The bot's own answer landing late keeps it.
    store.noteMessage(peer: peer, fromUserID: bot, messageID: 11)
    #expect(store.suggestion(for: peer) != nil)

    store.noteMessage(peer: peer, fromUserID: user, messageID: 12)
    #expect(store.suggestion(for: peer) == nil)
  }

  @Test("A suggestion for a conversation that moved on is dropped")
  func staleOnArrival() {
    let store = ComposeSuggestions()
    store.noteMessage(peer: peer, fromUserID: user, messageID: 12)
    store.noteMessage(peer: peer, fromUserID: bot, messageID: 13)
    store.apply(update("yes", after: 10))
    #expect(store.suggestion(for: peer) == nil)

    store.apply(update("commit this", after: 12))
    #expect(store.suggestion(for: peer)?.text == "commit this")
  }

  @Test("Empty text clears only that bot's suggestion; dismiss clears it")
  func clearing() {
    let store = ComposeSuggestions()
    store.apply(update("try it"))
    store.apply(update("", from: 99))
    #expect(store.suggestion(for: peer) != nil)
    store.apply(update(""))
    #expect(store.suggestion(for: peer) == nil)

    store.apply(update("push it"))
    store.dismiss(peer: peer)
    #expect(store.suggestion(for: peer) == nil)
  }

  @Test("Changes are published per peer")
  func publishes() {
    let store = ComposeSuggestions()
    var changed: [InlineKit.Peer] = []
    let cancellable = store.changes.sink { changed.append($0) }
    store.apply(update("yes"))
    store.apply(update("yes"))
    store.dismiss(peer: peer)
    store.dismiss(peer: peer)
    #expect(changed == [peer, peer])
    cancellable.cancel()
  }
}
