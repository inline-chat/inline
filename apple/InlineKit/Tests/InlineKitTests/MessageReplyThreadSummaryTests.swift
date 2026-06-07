import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Message Reply Thread Summary")
struct MessageReplyThreadSummaryTests {
  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("protocol replies are persisted in content payload and exposed via helpers")
  func protocolRepliesPersistedAndReadable() {
    var proto = InlineProtocol.Message()
    proto.id = 101
    proto.chatID = 44
    proto.fromID = 9
    proto.date = 1
    proto.out = false
    proto.peerID = .with {
      $0.chat.chatID = 44
    }
    proto.message = "hello"
    proto.replies = .with {
      $0.chatID = 77
      $0.replyCount = 3
      $0.hasUnread_p = true
      $0.recentReplierUserIds = [2, 3]
    }

    let msg = Message(from: proto)

    #expect(msg.contentPayload?.hasReplies == true)
    #expect(msg.replyThreadSummary?.chatID == 77)
    #expect(msg.replyThreadSummary?.replyCount == 3)
    #expect(msg.replyThreadSummary?.hasUnread_p == true)
    #expect(msg.replyThreadRecentReplierUserIds == [2, 3])
    #expect(msg.replyThreadPeer == .thread(id: 77))
    #expect(msg.hasReplyThreadSummary == true)
  }

  @Test("setVoiceContent preserves replies in payload")
  func setVoiceContentPreservesReplies() {
    var msg = Message(
      messageId: 12,
      fromId: 4,
      date: Date(timeIntervalSince1970: 1),
      text: "x",
      peerUserId: 4,
      peerThreadId: nil,
      chatId: 88,
      contentPayload: .with {
        $0.replies = .with {
          $0.chatID = 99
          $0.replyCount = 1
        }
      }
    )

    msg.setVoiceContent(nil)

    #expect(msg.contentPayload?.hasReplies == true)
    #expect(msg.replyThreadRecentReplierUserIds.isEmpty)
    #expect(msg.replyThreadPeer == .thread(id: 99))
    #expect(msg.hasReplyThreadSummary == true)
  }

  @Test("summary is hidden when replyCount is zero")
  func summaryHiddenWhenReplyCountIsZero() {
    var proto = InlineProtocol.Message()
    proto.id = 102
    proto.chatID = 44
    proto.fromID = 9
    proto.date = 1
    proto.out = false
    proto.peerID = .with {
      $0.chat.chatID = 44
    }
    proto.message = "hello"
    proto.replies = .with {
      $0.chatID = 88
      $0.replyCount = 0
      $0.hasUnread_p = false
    }

    let msg = Message(from: proto)

    #expect(msg.replyThreadSummary != nil)
    #expect(msg.hasReplyThreadSummary == false)
    #expect(msg.replyThreadPeer == .thread(id: 88))
  }

  @Test("full message preloads reply thread chat metadata")
  func fullMessagePreloadsReplyThreadChatMetadata() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try User(id: 1, email: "sender@example.com", firstName: "Sender", lastName: nil, username: "sender")
        .insert(db)

      try Chat(
        id: 44,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Parent",
        spaceId: nil
      ).insert(db)

      var message = Message(
        messageId: 101,
        fromId: 1,
        date: Date(timeIntervalSince1970: 2),
        text: "hello",
        peerUserId: nil,
        peerThreadId: 44,
        chatId: 44,
        contentPayload: .with {
          $0.replies = .with {
            $0.chatID = 77
            $0.replyCount = 2
          }
        }
      )
      try message.saveMessage(db)

      try Chat(
        id: 77,
        date: Date(timeIntervalSince1970: 3),
        type: .thread,
        title: "Design replies",
        spaceId: nil,
        isUntitled: false,
        parentChatId: 44,
        parentMessageId: 101
      ).insert(db)

      let fullMessage = try #require(try FullMessage.queryRequest()
        .filter(Column("chatId") == 44)
        .filter(Column("messageId") == 101)
        .fetchOne(db))

      #expect(fullMessage.replyThread?.id == 77)
      #expect(fullMessage.replyThreadCustomTitle == "Design replies")
      #expect(fullMessage.message.hasReplyThreadSummary == true)
    }
  }
}
