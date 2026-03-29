import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Reply thread persistence")
struct ReplyThreadPersistenceTests {
  private let chatId: Int64 = 41
  private let parentChatId: Int64 = 7
  private let parentMessageId: Int64 = 99
  private let senderId: Int64 = 123

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
    _ = try AppDatabase(queue)
    return queue
  }

  private func seedChatDependencies(_ db: Database) throws {
    try User(
      id: senderId,
      email: nil,
      firstName: "Sender",
      lastName: nil,
      username: nil
    ).insert(db)

    try Chat(
      id: chatId,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: "Thread",
      spaceId: nil
    ).insert(db)
  }

  private func makeReplies() -> InlineProtocol.MessageReplies {
    .with {
      $0.chatID = 5001
      $0.replyCount = 3
      $0.hasUnread_p = true
      $0.recentReplierUserIds = [42, 43]
    }
  }

  private func makeProtocolMessage(includeReplies: Bool) -> InlineProtocol.Message {
    .with {
      $0.id = 10
      $0.chatID = chatId
      $0.fromID = senderId
      $0.date = 2
      $0.peerID = .with {
        $0.chat.chatID = chatId
      }
      $0.message = includeReplies ? "hello" : "edited"
      if includeReplies {
        $0.replies = makeReplies()
      }
    }
  }

  @Test("Chat(from:) keeps parent chat and message ids")
  func chatFromProtoKeepsParentIDs() throws {
    let dbQueue = try makeInMemoryDB()

    var proto = InlineProtocol.Chat()
    proto.id = chatId
    proto.date = 2
    proto.title = "Reply Thread"
    proto.peerID = .with {
      $0.chat.chatID = chatId
    }
    proto.parentChatID = parentChatId
    proto.parentMessageID = parentMessageId

    try dbQueue.write { db in
      try Chat(
        id: parentChatId,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Parent Thread",
        spaceId: nil
      ).insert(db)

      try Chat(from: proto).save(db)

      let row = try Row.fetchOne(
        db,
        sql: "SELECT parentChatId, parentMessageId FROM chat WHERE id = ?",
        arguments: [chatId]
      )

      #expect(row != nil)
      #expect(row?["parentChatId"] as Int64? == parentChatId)
      #expect(row?["parentMessageId"] as Int64? == parentMessageId)
    }
  }

  @Test("Message(from:) keeps replies on contentPayload")
  func messageFromProtoKeepsReplies() {
    let message = Message(from: makeProtocolMessage(includeReplies: true))

    #expect(message.contentPayload?.hasReplies == true)
    #expect(message.contentPayload?.replies.chatID == 5001)
    #expect(message.contentPayload?.replies.replyCount == 3)
    #expect(message.contentPayload?.replies.hasUnread_p == true)
    #expect(message.contentPayload?.replies.recentReplierUserIds == [42, 43])
  }

  @Test("Message.save preserves existing replies in contentPayload when an unrelated edit omits replies")
  func messageSavePreservesRepliesAcrossEdits() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedChatDependencies(db)

      _ = try Message.save(
        db,
        protocolMessage: makeProtocolMessage(includeReplies: true),
        publishChanges: false
      )

      _ = try Message.save(
        db,
        protocolMessage: makeProtocolMessage(includeReplies: false),
        publishChanges: false
      )

      let stored = try Message.fetchOne(db, key: ["messageId": 10, "chatId": chatId])
      #expect(stored != nil)
      #expect(stored?.contentPayload?.hasReplies == true)
      #expect(stored?.contentPayload?.replies.chatID == 5001)
      #expect(stored?.contentPayload?.replies.replyCount == 3)
      #expect(stored?.text == "edited")
    }
  }

  @Test("Client_MessageContentPayload codable preserves voice actions and replies")
  func messageContentPayloadCodableRoundTripsAllFields() throws {
    let payload = Client_MessageContentPayload.with {
      $0.voice = Client_MessageVoiceContent.with {
        $0.voiceID = 77
        $0.duration = 12
      }
      $0.actions = InlineProtocol.MessageActions.with {
        $0.rows = [
          .with {
            $0.actions = [
              .with {
                $0.actionID = "ack"
                $0.text = "Ack"
              }
            ]
          }
        ]
      }
      $0.replies = makeReplies()
    }

    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(Client_MessageContentPayload.self, from: data)

    #expect(decoded.hasVoice)
    #expect(decoded.voice.voiceID == 77)
    #expect(decoded.hasActions)
    #expect(decoded.actions.rows.count == 1)
    #expect(decoded.actions.rows.first?.actions.first?.actionID == "ack")
    #expect(decoded.hasReplies)
    #expect(decoded.replies.chatID == 5001)
    #expect(decoded.replies.replyCount == 3)
  }

  @Test("Message.deleteMessages orphans linked reply threads when deleting the anchor")
  func messageDeleteOrphansLinkedReplyThreads() throws {
    let dbQueue = try makeInMemoryDB()
    let childChatId: Int64 = 5001

    try dbQueue.write { db in
      try User(
        id: senderId,
        email: nil,
        firstName: "Sender",
        lastName: nil,
        username: nil
      ).insert(db)

      try Chat(
        id: parentChatId,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Parent",
        spaceId: nil,
        lastMsgId: parentMessageId
      ).insert(db)

      try Chat(
        id: childChatId,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: "Re: Parent",
        spaceId: nil,
        parentChatId: parentChatId,
        parentMessageId: parentMessageId
      ).insert(db)

      var anchorProto = InlineProtocol.Message()
      anchorProto.id = parentMessageId
      anchorProto.chatID = parentChatId
      anchorProto.fromID = senderId
      anchorProto.date = 3
      anchorProto.peerID = .with {
        $0.chat.chatID = parentChatId
      }
      anchorProto.message = "anchor"
      _ = try Message.save(db, protocolMessage: anchorProto, publishChanges: false)

      try Message.deleteMessages(db, messageIds: [parentMessageId], chatId: parentChatId)

      let orphanedChildChat = try Chat.fetchOne(db, id: childChatId)
      let deletedParentMessage = try Message.fetchOne(
        db,
        key: ["messageId": parentMessageId, "chatId": parentChatId]
      )

      #expect(orphanedChildChat?.parentChatId == parentChatId)
      #expect(orphanedChildChat?.parentMessageId == nil)
      #expect(deletedParentMessage == nil)
    }
  }
}
