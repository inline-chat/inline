import Foundation
import InlineProtocol
import Testing
@testable import InlineAppIntents

@Suite("Inline intent message boundaries")
struct InlineIntentMessageTests {
  @Test("reply identity cannot cross account or conversation namespaces")
  func replyIdentity() throws {
    let chat = InlineIntentChatID(accountID: 9, chatID: Int64.max)
    let id = InlineIntentMessageID(chat: chat, messageID: Int64.max)
    #expect(InlineIntentMessageID(id.rawValue) == id)
    #expect(try InlineIntentMessaging.replyID(id.rawValue, in: chat) == Int64.max)
    #expect(throws: InlineIntentError.self) { try InlineIntentMessaging.replyID(id.rawValue, in: .init(accountID: 8, chatID: Int64.max)) }
    #expect(throws: InlineIntentError.self) { try InlineIntentMessaging.replyID(id.rawValue, in: .init(accountID: 9, chatID: 2)) }
    for invalid in ["m1:9:2:0", "m1:9:2:-1", "m1:9:2:3:4", "m1::2:3", "m2:9:2:3"] {
      #expect(InlineIntentMessageID(invalid) == nil)
    }
  }

  @Test("unread conversation pagination reports the whole count without silently dropping chats")
  func unreadPages() throws {
    let inbox = snapshot(count: 43)
    let first = try inbox.unreadPage(after: nil)
    #expect(first.totalCount == 43)
    #expect(first.conversations.count == 20)
    let second = try inbox.unreadPage(after: #require(first.nextCursor))
    let third = try inbox.unreadPage(after: #require(second.nextCursor))
    #expect(second.conversations.count == 20)
    #expect(third.conversations.map(\.chat.id.chatID) == [3, 2, 1])
    #expect(third.nextCursor == nil)
    #expect(throws: InlineIntentError.self) { try inbox.unreadPage(after: "v1:8:20") }
  }

  @Test("unread catch-up follows All Chats and never treats Inbox placement as access")
  func unreadProjection() throws {
    var result = payload(count: 4)
    result.dialogs[0].open = false
    result.dialogs[1].open = true
    result.dialogs[2].archived = true
    result.dialogs[3].chatListHidden = true

    let page = try InlineIntentInbox(result, accountID: 9).unreadPage(after: nil)

    #expect(page.conversations.map(\.chat.id.chatID) == [2, 1])
    #expect(page.totalCount == 2)
    #expect(page.conversations.last?.dialog.open == false)
  }

  @Test("outgoing-only pages advance and subsequent incoming messages retain exact text")
  func outgoingPage() throws {
    let inbox = snapshot()
    let chat = try inbox.conversation("v1:9:1")
    let outgoing = (Int64(11)...30).map { source(id: $0, out: true) }
    let first = try InlineIntentMessaging.page(outgoing, conversation: chat, inbox: inbox, unreadOnly: true, afterID: 10, newer: true)
    #expect(first.messages.isEmpty)
    #expect(first.nextCursor == "m1:9:1:30")
    var incoming = source(id: 31)
    incoming.message = "  Original 👋\nline 2  "
    let next = try InlineIntentMessaging.page([incoming], conversation: chat, inbox: inbox, unreadOnly: true, afterID: 30, newer: true)
    #expect(next.messages.first?.text == incoming.message)
    #expect(next.messages.first?.isRead == false)
    #expect(next.nextCursor == nil)
  }

  @Test("historical authors resolve from public profiles without a current participant or read receipt")
  func historicalAuthor() throws {
    let inbox = snapshot()
    let chat = try inbox.conversation("v1:9:1")
    let author = InlineProtocol.User.with { $0.id = 8; $0.firstName = "Former Member"; $0.username = "renamed" }
    let hydrated = inbox.addingUsers([author])
    let page = try InlineIntentMessaging.page(
      [source(id: 11)], conversation: chat, inbox: hydrated, unreadOnly: true, afterID: 10, newer: true
    )
    #expect(page.messages.first?.author == "Former Member")
    #expect(page.messages.first?.authorUsername == "renamed")
    #expect(page.messages.first?.isRead == false)
    #expect(try hydrated.conversation(chat.chat.id.rawValue).dialog.readMaxID == 10)
    #expect(inbox.users.isEmpty)
    let unavailable = try InlineIntentMessage(source(id: 11), conversation: chat, inbox: inbox)
    #expect(unavailable.author == String(localized: "Unknown Sender"))
  }

  @Test("wrong-chat, stale and oversized pages fail closed")
  func invalidPages() throws {
    let inbox = snapshot()
    let chat = try inbox.conversation("v1:9:1")
    var wrongChat = source(id: 11)
    wrongChat.chatID = 2
    for sources in [[wrongChat], [source(id: 10)], (Int64(11)...31).map { source(id: $0) }] {
      #expect(throws: InlineIntentError.self) {
        try InlineIntentMessaging.page(sources, conversation: chat, inbox: inbox, unreadOnly: true, afterID: 10, newer: true)
      }
    }
  }

  @Test("collapsed history cannot be resolved and outgoing receipts are never invented")
  func collapsedHistory() throws {
    let inbox = snapshot()
    let chat = try inbox.conversation("v1:9:1")
    #expect(chat.dialog.open == false)
    #expect(throws: InlineIntentError.self) { try InlineIntentMessage(source(id: 5), conversation: chat, inbox: inbox) }
    #expect(try InlineIntentMessage(source(id: 9), conversation: chat, inbox: inbox).isRead)
    #expect(try !InlineIntentMessage(source(id: 9, out: true), conversation: chat, inbox: inbox).isRead)
    #expect(throws: InlineIntentError.self) { try inbox.conversation("v1:8:1") }
  }

  @Test("snapshot preserves placement flags, rejects mismatched dialogs and tolerates duplicate users")
  func snapshotVisibility() throws {
    var result = payload(count: 3)
    result.dialogs[0].chatListHidden = true
    result.dialogs[1].peer = .with { $0.chat = .with { $0.chatID = 3 } }
    result.users = [.with { $0.id = 9; $0.firstName = "First" }, .with { $0.id = 9; $0.firstName = "Updated" }]
    let inbox = InlineIntentInbox(result, accountID: 9)
    #expect(inbox.conversations.map(\.chat.id.chatID) == [3, 1])
    #expect(InlineIntentChatStore.fetch(in: inbox).map(\.id.chatID) == [3])
    #expect(inbox.users[9]?.firstName == "Updated")
  }

  private func snapshot(count: Int64 = 1) -> InlineIntentInbox { .init(payload(count: count), accountID: 9) }
  private func payload(count: Int64) -> GetChatsResult {
    .with { result in
      for id in 1...count {
        let peer = InlineProtocol.Peer.with { $0.chat = .with { $0.chatID = id } }
        result.chats.append(.with { $0.id = id; $0.peerID = peer; $0.title = "Chat \(id)" })
        result.dialogs.append(.with {
          $0.chatID = id; $0.peer = peer; $0.unreadCount = 1; $0.readMaxID = 10; $0.collapsedMaxID = 5
        })
      }
    }
  }
  private func source(id: Int64, out: Bool = false) -> InlineProtocol.Message {
    .with { $0.id = id; $0.chatID = 1; $0.fromID = out ? 9 : 8; $0.out = out; $0.message = "Message \(id)" }
  }
}
