import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Reply thread chat item resolution")
struct ReplyThreadChatItemResolutionTests {
  private let childChatId: Int64 = 41

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("thread chat resolves without a dialog row")
  func threadChatResolvesWithoutDialog() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try Chat(
        id: childChatId,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Re: anchor",
        spaceId: nil,
        parentChatId: 7,
        parentMessageId: 99
      ).insert(db)

      let chatItem = try FullChatViewModel.resolveChatItem(in: db, for: .thread(id: childChatId))

      #expect(chatItem?.chat?.id == childChatId)
      #expect(chatItem?.dialog.chatId == childChatId)
      #expect(chatItem?.dialog.peerId == .thread(id: childChatId))
    }
  }
}
