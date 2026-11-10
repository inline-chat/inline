import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

private typealias Chat = InlineKit.Chat

@Suite("Linked thread access")
struct LinkedThreadAccessTests {
  private let me: Int64 = 1
  private let cofounder: Int64 = 2
  private let teammate: Int64 = 3

  @Test("finds chat ids in links, message links, and thread entities")
  func parsesLinks() {
    var thread = MessageEntity()
    thread.type = .thread
    thread.thread.chatID = 77
    var textURL = MessageEntity()
    textURL.type = .textURL
    textURL.textURL.url = "https://inline.chat/c/88"
    var entities = MessageEntities()
    entities.entities = [thread, textURL]

    let ids = LinkedThreadAccess.linkedChatIds(
      text: "see inline.chat/c/34 and https://inline.chat/c/34 plus inline://chat/56",
      entities: entities
    )

    #expect(ids == [77, 88, 34])
    #expect(LinkedThreadAccess.chatId(fromLink: "inline://chat/56") == 56)
    #expect(LinkedThreadAccess.linkedChatIds(text: "https://example.com/c/34", entities: nil).isEmpty)
  }

  @Test("flags the DM peer missing from a private thread the sender is in")
  func flagsDMPeer() throws {
    let queue = try fixture()
    let gaps = try queue.read { db in
      try LinkedThreadAccess.gaps(db, linkedChatIds: [10], destination: .user(id: cofounder), currentUserId: me)
    }

    #expect(gaps.map(\.chat.id) == [10])
    #expect(gaps.first?.users.map(\.user.id) == [cofounder])
    #expect(gaps.first?.chatTitle == "Launch plan")
  }

  @Test("stays quiet when the recipient already has access or the roster isn't ours")
  func quietCases() throws {
    let queue = try fixture()
    let (alreadyIn, unloaded, publicThread) = try queue.read { db in
      (
        try LinkedThreadAccess.gaps(db, linkedChatIds: [10], destination: .user(id: teammate), currentUserId: me),
        // Thread 11's participants never loaded, so we can't tell who's missing.
        try LinkedThreadAccess.gaps(db, linkedChatIds: [11], destination: .user(id: cofounder), currentUserId: me),
        // Public threads aren't something we can add people to.
        try LinkedThreadAccess.gaps(db, linkedChatIds: [12], destination: .user(id: cofounder), currentUserId: me)
      )
    }
    #expect(alreadyIn.isEmpty)
    #expect(unloaded.isEmpty)
    #expect(publicThread.isEmpty)
  }

  @Test("checks every member of a private destination thread")
  func flagsThreadRecipients() throws {
    let queue = try fixture()
    try queue.write { db in
      try Chat(id: 20, date: Date(), type: .thread, title: "General", spaceId: nil, isPublic: false).insert(db)
      for userId in [me, cofounder, teammate] {
        try ChatParticipant(chatId: 20, userId: userId, date: Date()).insert(db)
      }
    }
    let gaps = try queue.read { db in
      try LinkedThreadAccess.gaps(db, linkedChatIds: [10], destination: .thread(id: 20), currentUserId: me)
    }
    #expect(gaps.first?.users.map(\.user.id) == [cofounder])
  }

  private func fixture() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try User(id: me, email: nil, firstName: "Mo").insert(db)
      try User(id: cofounder, email: nil, firstName: "Dena").insert(db)
      try User(id: teammate, email: nil, firstName: "Sam").insert(db)
      try Chat(id: 10, date: Date(), type: .thread, title: "Launch plan", spaceId: nil, isPublic: false).insert(db)
      try ChatParticipant(chatId: 10, userId: me, date: Date()).insert(db)
      try ChatParticipant(chatId: 10, userId: teammate, date: Date()).insert(db)
      try Chat(id: 11, date: Date(), type: .thread, title: "Unloaded", spaceId: nil, isPublic: false).insert(db)
      try Chat(id: 12, date: Date(), type: .thread, title: "Town hall", spaceId: nil, isPublic: true).insert(db)
    }
    return queue
  }
}
