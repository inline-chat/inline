import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Activity items")
struct ActivityItemTests {
  private let chatId: Int64 = 900

  private var peer: InlineProtocol.Peer {
    .with { $0.chat = .with { $0.chatID = chatId } }
  }

  private func seed(_ db: Database, mentions: Int32? = nil, reactions: Int32 = 0) throws {
    if try Chat.fetchOne(db, id: chatId) == nil {
      try Chat(id: chatId, date: .init(timeIntervalSince1970: 1), type: .thread, title: "Activity", spaceId: nil)
        .insert(db)
    }
    let dialog = InlineProtocol.Dialog.with {
      $0.peer = peer
      $0.chatID = chatId
      if let mentions {
        $0.unreadMentionsCount = mentions
        $0.unreadReactionsCount = reactions
      }
    }
    try dialog.saveFull(db)
  }

  private func dialog(_ db: Database) throws -> InlineKit.Dialog {
    try #require(try InlineKit.Dialog.fetchOne(db, id: InlineKit.Dialog.getDialogId(peerThreadId: chatId)))
  }

  private func update(
    mentions: Int32,
    reactions: Int32 = 0,
    unreadMentions: [Int64] = [],
    unreadReactions: [Int64] = [],
    cleared: [Int64] = []
  ) -> InlineProtocol.UpdateUnreadActivity {
    .with {
      $0.peerID = peer
      $0.unreadMentionsCount = mentions
      $0.unreadReactionsCount = reactions
      $0.unreadMentionIds = unreadMentions
      $0.unreadReactionIds = unreadReactions
      $0.clearedMessageIds = cleared
    }
  }

  private func oldest(_ db: Database, _ kind: ChatActivityItem.Kind = .mention) throws -> Int64? {
    try ChatActivityItem.oldestUnread(db, chatId: chatId, kind: kind)?.messageId
  }

  @Test("Dialog keeps its counts when a dialog payload omits them")
  func dialogCountsSurviveMissingField() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try seed(db, mentions: 3, reactions: 1)
      #expect(try dialog(db).unreadMentionsCount == 3)

      // An older server or a partial dialog payload must not erase known counts.
      try seed(db)
      #expect(try dialog(db).unreadMentionsCount == 3)
      #expect(try dialog(db).unreadReactionsCount == 1)
    }
  }

  @Test("Updates add and clear rows and the oldest of each kind is next")
  func updatesAndNavigationOrder() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try seed(db)
      try update(mentions: 3, reactions: 1, unreadMentions: [30, 10, 20], unreadReactions: [5]).apply(db)
      #expect(try oldest(db) == 10)
      #expect(try oldest(db, .reaction) == 5)
      #expect(try dialog(db).unreadMentionsCount == 3)

      try update(mentions: 2, reactions: 0, cleared: [10, 5]).apply(db)
      #expect(try oldest(db) == 20)
      #expect(try oldest(db, .reaction) == nil)
    }
  }

  @Test("Local reads hide rows until the server confirms them")
  func pendingReadsSubtractFromServerCounts() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try seed(db)
      try update(mentions: 3, unreadMentions: [1, 2, 3]).apply(db)

      let marked = try ChatActivityItem.markPendingRead(db, chatId: chatId, messageIds: [1, 2])
      #expect(marked.count == 2)
      #expect(try dialog(db).unreadMentionsCount == 1)
      #expect(try oldest(db) == 3)

      // A new mention arrives with counts computed before the server saw the read.
      try update(mentions: 4, unreadMentions: [4]).apply(db)
      #expect(try dialog(db).unreadMentionsCount == 2)

      // The read confirmation clears the pending rows; the count stays right.
      try update(mentions: 2, cleared: [1, 2]).apply(db)
      #expect(try dialog(db).unreadMentionsCount == 2)
      #expect(try ChatActivityItem.filter(ChatActivityItem.Columns.pendingRead == true).fetchCount(db) == 0)
    }
  }

  @Test("A read of a row the server had already read clears through the echo")
  func staleRowClearsThroughEcho() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try seed(db, mentions: 1)
      // A history page flagged 7 just before another device read it; the server count is 1 (for 8).
      try update(mentions: 1, unreadMentions: [8]).apply(db)
      try ChatActivityItem.insertFromHistory(db, chatId: chatId, messages: [
        .with { $0.id = 7; $0.unreadMention = true },
      ])
      #expect(try oldest(db) == 7)

      try ChatActivityItem.markPendingRead(db, chatId: chatId, messageIds: [7])
      #expect(try dialog(db).unreadMentionsCount == 0) // briefly low until the echo lands

      // The server changes nothing but echoes 7 with its counts; the pending row goes.
      try update(mentions: 1, cleared: [7]).apply(db)
      #expect(try dialog(db).unreadMentionsCount == 1)
      #expect(try oldest(db) == 8)
    }
  }

  @Test("History flags add rows without touching pending ones")
  func historyFlagsOnlyAdd() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try seed(db, mentions: 2, reactions: 1)
      try update(mentions: 2, reactions: 1, unreadMentions: [3]).apply(db)
      try ChatActivityItem.markPendingRead(db, chatId: chatId, messageIds: [3])

      try ChatActivityItem.insertFromHistory(db, chatId: chatId, messages: [
        .with { $0.id = 3; $0.unreadMention = true },
        .with { $0.id = 4; $0.unreadMention = true },
        .with { $0.id = 5; $0.unreadReactions = true },
        .with { $0.id = 6 },
      ])
      let rows = try ChatActivityItem.order(ChatActivityItem.Columns.messageId).fetchAll(db)
      #expect(rows.map(\.messageId) == [3, 4, 5])
      #expect(rows.map(\.kind) == [.mention, .mention, .reaction])
      #expect(rows.first?.pendingRead == true)
    }
  }

  @Test("A failed read restores the rows and counts")
  func rollbackRestoresItems() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try seed(db)
      try update(mentions: 2, unreadMentions: [1, 2]).apply(db)
      let marked = try ChatActivityItem.markPendingRead(db, chatId: chatId, messageIds: [1])
      try ChatActivityItem.rollbackPendingRead(db, items: marked)
      #expect(try dialog(db).unreadMentionsCount == 2)
      #expect(try oldest(db) == 1)
    }
  }

  @Test("A kind the server reports as empty drops its local rows")
  func emptyServerKindDropsRows() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try seed(db)
      try update(mentions: 1, reactions: 1, unreadMentions: [1], unreadReactions: [2]).apply(db)
      try ChatActivityItem.markPendingRead(db, chatId: chatId, messageIds: [1])

      try update(mentions: 0, reactions: 1).apply(db)
      #expect(try ChatActivityItem.filter(ChatActivityItem.Columns.kind == ChatActivityItem.Kind.mention.rawValue).fetchCount(db) == 0)
      #expect(try dialog(db).unreadMentionsCount == 0)
      #expect(try dialog(db).unreadReactionsCount == 1)
    }
  }

  @Test("A dialog snapshot leaves counts alone while reads are in flight")
  func snapshotWaitsForPendingReads() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try seed(db)
      try update(mentions: 2, unreadMentions: [1, 2]).apply(db)
      try ChatActivityItem.markPendingRead(db, chatId: chatId, messageIds: [1])
      #expect(try dialog(db).unreadMentionsCount == 1)

      // The server already processed the read: subtracting the pending row again would show 0.
      try seed(db, mentions: 1)
      #expect(try dialog(db).unreadMentionsCount == 1)

      // Once the read is confirmed, snapshots apply again.
      try update(mentions: 1, cleared: [1]).apply(db)
      try seed(db, mentions: 3)
      #expect(try dialog(db).unreadMentionsCount == 3)
    }
  }

  @Test("Mark all is bounded by the newest known message")
  func markAllBound() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try seed(db)
      try update(mentions: 3, unreadMentions: [1, 2, 9]).apply(db)
      try ChatActivityItem.markAllPendingRead(db, chatId: chatId, kinds: [.mention], maxId: 2)
      #expect(try dialog(db).unreadMentionsCount == 1)
      #expect(try oldest(db) == 9)
      #expect(try ChatActivityItem.markAllBound(db, chatId: chatId) == 9)
    }
  }

  @Test("A complete refill keeps pending rows the server still lists and drops the rest of that kind")
  func refillKeepsPendingRows() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try seed(db)
      try update(mentions: 3, reactions: 1, unreadMentions: [1, 2, 3], unreadReactions: [4]).apply(db)
      // 1 is still unread on the server (its read is in flight); 2 was already read there.
      try ChatActivityItem.markPendingRead(db, chatId: chatId, messageIds: [1, 2])

      try ChatActivityItem.replaceUnread(db, chatId: chatId, kind: .mention, messageIds: [1, 5], complete: true)
      let rows = try ChatActivityItem.order(ChatActivityItem.Columns.messageId).fetchAll(db)
      #expect(rows.map(\.messageId) == [1, 4, 5])
      #expect(rows.first?.pendingRead == true)
    }
  }

  @Test("Chat list rows pick one badge, mention first")
  func chatListBadgePriority() {
    let peer = Peer.thread(id: chatId)
    #expect(ChatListItemSnapshot(peer: peer, chatID: chatId, title: "a").activityBadge == nil)
    #expect(ChatListItemSnapshot(peer: peer, chatID: chatId, title: "a", unreadMentionsCount: 1, unreadReactionsCount: 3).activityBadge == .mention)
    let reacted = ChatListItemSnapshot(peer: peer, chatID: chatId, title: "a", unreadReactionsCount: 3)
    #expect(reacted.activityBadge == .reaction)
    #expect(reacted.needsAttention)
    #expect(!reacted.matchesUnreadFilter)
    #expect(ChatListActivityBadge.strongest(.reaction, .mention) == .mention)
    #expect(ChatListActivityBadge.strongest(nil, .reaction) == .reaction)
  }
}
