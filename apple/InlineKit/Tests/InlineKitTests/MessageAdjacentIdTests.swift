import Foundation
import GRDB
import Synchronization
import Testing

@testable import InlineKit

@Suite("Message adjacent id")
struct MessageAdjacentIdTests {
  private final class StatementLog: Sendable {
    let statements = Mutex<[String]>([])
  }

  private let log = StatementLog()

  private func makeQueue() throws -> DatabaseQueue {
    var configuration = AppDatabase.makeConfiguration(passphrase: "123")
    configuration.prepareDatabase { [log] db in
      db.trace(options: .statement) { event in
        log.statements.withLock { $0.append(event.expandedDescription) }
      }
    }
    let queue = try DatabaseQueue(configuration: configuration)
    _ = try AppDatabase(queue)
    try queue.write { db in
      try User(id: 1, email: nil, firstName: "A").insert(db)
      try User(id: 2, email: nil, firstName: "B").insert(db)
      try Chat(id: 1, date: Date(), type: .thread, title: "One", spaceId: nil).insert(db)
      try Chat(id: 2, date: Date(), type: .thread, title: "Two", spaceId: nil).insert(db)
      try Chat(id: 3, date: Date(), type: .privateChat, title: nil, spaceId: nil, peerUserId: 2).insert(db)
      // Chat 2 interleaves with chat 1 so a lookup that ignored the chat would
      // return its rows; -5 is an unsent optimistic row.
      let rows: [(chat: Int64, ids: [Int64])] = [(1, [-5, 10, 20, 30, 40]), (2, [15, 25, 35, 45]), (3, [10, 20])]
      for (chat, ids) in rows {
        for id in ids {
          try Message(
            messageId: id, fromId: 1, date: Date(timeIntervalSince1970: TimeInterval(1_000 + abs(id))), text: "m",
            peerUserId: chat == 3 ? 2 : nil, peerThreadId: chat == 3 ? nil : chat, chatId: chat
          ).insert(db)
        }
      }
    }
    return queue
  }

  @Test("returns the nearest saved server id on each side within one peer")
  func nearestWithinPeer() throws {
    let queue = try makeQueue()
    try queue.read { db in
      let thread = Peer.thread(id: 1)
      try #expect(Message.adjacentMessageId(db, chatId: 1, peer: thread, .older, of: 30) == 20)
      try #expect(Message.adjacentMessageId(db, chatId: 1, peer: thread, .newer, of: 30) == 40)
      try #expect(Message.adjacentMessageId(db, chatId: 1, peer: thread, .newer, of: 40) == nil)
      // Optimistic negative ids are never candidates.
      try #expect(Message.adjacentMessageId(db, chatId: 1, peer: thread, .older, of: 10) == nil)
      try #expect(Message.adjacentMessageId(db, chatId: 1, peer: thread, .newer, of: 0) == 10)

      let user = Peer.user(id: 2)
      try #expect(Message.adjacentMessageId(db, chatId: 3, peer: user, .older, of: 20) == 10)
      try #expect(Message.adjacentMessageId(db, chatId: 3, peer: user, .newer, of: 20) == nil)
      // Rows saved under another peer of the same chat id do not match.
      try #expect(Message.adjacentMessageId(db, chatId: 3, peer: .thread(id: 3), .older, of: 20) == nil)
    }
  }

  @Test("window metadata reads candidates from the chat index without loading messages")
  func windowMetadataStaysIndexOnly() throws {
    let queue = try makeQueue()
    let window = try queue.read { db in
      try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1)
        .filter(Column("messageId") == 20 || Column("messageId") == 30)
        .fetchAll(db)
    }
    #expect(window.count == 2)

    log.statements.withLock { $0.removeAll() }
    let metadata = try queue.read { db in
      try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: .thread(id: 1), messages: window)
    }
    let selects = log.statements.withLock { $0 }.filter { $0.hasPrefix("SELECT") }

    #expect(metadata.oldestLoadedMessageId == 20)
    #expect(metadata.newestLoadedMessageId == 30)
    // Holes plus one seek per side; the previous shape ran 37 statements.
    #expect(selects.count == 3)
    #expect(selects.allSatisfy { !$0.contains("JOIN") })

    try queue.read { db in
      for sql in selects where sql.contains("FROM message") {
        let details = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)")
          .map { $0["detail"] as String }
          .joined(separator: " | ")
        #expect(details.contains("message_chat_message_idx"), "\(details)")
        #expect(!details.contains("TEMP B-TREE"), "\(details)")
      }
    }
  }
}
