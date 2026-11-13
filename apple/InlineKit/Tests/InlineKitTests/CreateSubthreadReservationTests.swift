import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import Auth
@testable import InlineKit
@testable import RealtimeV2

@Suite("Create subthread reservation")
struct CreateSubthreadReservationTests {
  private let accountID: Int64 = 1
  private let parentChatID: Int64 = 10
  private let reservedChatID: Int64 = 70
  private let existingChatID: Int64 = 80

  private func makeDatabase() throws -> AppDatabase {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try User(id: accountID, email: nil, firstName: "Author").insert(db)
      try Space(id: 5, name: "Space", date: Date()).insert(db)
      try Chat(
        id: parentChatID, date: Date(), type: .thread, title: "Parent", spaceId: 5, isPublic: false
      ).save(db)
    }
    return database
  }

  private var transaction: CreateSubthreadTransaction {
    .createSubthread(parentChatId: parentChatID, parentMessageId: 3, reservedChatId: reservedChatID)
  }

  @Test("the reserved shell inherits the parent's scope and blocks dependents until confirmed")
  func reservedShellIsPendingReplyThread() async throws {
    let database = try makeDatabase()
    try await database.dbWriter.write { db in
      try transaction.saveOptimisticState(db, currentUserId: accountID)
    }

    let (chat, dialog) = try await database.reader.read { db in
      (
        try Chat.fetchOne(db, key: reservedChatID),
        try Dialog.fetchOne(db, key: Dialog.getDialogId(peerThreadId: reservedChatID))
      )
    }
    #expect(chat?.createState == .pending)
    #expect(chat?.parentChatId == parentChatID)
    #expect(chat?.parentMessageId == 3)
    #expect(chat?.spaceId == 5)
    #expect(chat?.isPublic == false)
    #expect(chat?.isUntitled == true)
    #expect(dialog?.chatListHidden == true)
    #expect(transaction.satisfiedBlockersOnSuccess.isEmpty)

    let resolver = ChatTransactionBlockerResolver(database: database)
    #expect(await resolver.state(for: .chatCreated(chatId: reservedChatID)) == .blocked)
  }

  @Test("losing the race removes the shell, fails its dependents and keeps plain queued text in the draft")
  func losingReservationMovesUnsentTextToExistingThread() async throws {
    let database = try makeDatabase()
    let drafts = Drafts2(database: database)
    try await database.dbWriter.write { db in
      try transaction.saveOptimisticState(db, currentUserId: accountID)
      var message = Message(
        messageId: -123, randomId: 123, fromId: accountID, date: Date(), text: "First reply",
        peerUserId: nil, peerThreadId: reservedChatID, chatId: reservedChatID, out: true, status: .sending
      )
      try message.saveMessage(db)
      try Chat(id: existingChatID, date: Date(), type: .thread, title: "Existing", spaceId: 5).save(db)
    }
    drafts.updateText(peer: .thread(id: reservedChatID), text: "Still typing")
    drafts.updateText(peer: .thread(id: existingChatID), text: "Older draft")

    let unsent = try await database.dbWriter.write { db in
      try CreateSubthreadTransaction.removeShell(db, chatId: reservedChatID, redirectingTo: existingChatID)
    }
    CreateSubthreadTransaction.moveDraft(
      from: reservedChatID,
      to: existingChatID,
      unsentTexts: unsent,
      drafts: drafts
    )

    #expect(unsent == ["First reply"])
    let leftovers = try await database.reader.read { db in
      (
        try Chat.fetchOne(db, key: reservedChatID),
        try Dialog.fetchOne(db, key: Dialog.getDialogId(peerThreadId: reservedChatID)),
        try Message.filter(Message.Columns.chatId == reservedChatID).fetchCount(db)
      )
    }
    #expect(leftovers.0 == nil)
    #expect(leftovers.1 == nil)
    #expect(leftovers.2 == 0)

    let resolver = ChatTransactionBlockerResolver(database: database)
    #expect(await resolver.state(for: .chatCreated(chatId: reservedChatID)) == .failed)
    #expect(await resolver.state(for: .chatCreated(chatId: existingChatID)) == .satisfied)
    let recovered = try await database.reader.read { db in
      try Message.fetchOne(db, key: ["messageId": -123, "chatId": existingChatID])
    }
    #expect(recovered == nil)

    #expect(drafts.load(peer: .thread(id: existingChatID))?.text == "First reply\n\nStill typing\n\nOlder draft")
    #expect(drafts.load(peer: .thread(id: reservedChatID))?.text ?? "" == "")
  }

  @Test("redirect retains media identity, caption and retry destination", arguments: ["photo", "document", "voice"])
  @MainActor
  func redirectRetainsPendingMedia(kind: String) async throws {
    let database = try makeDatabase()
    let auth = Auth.mocked(authenticated: true)
    // Retry admission is guarded process-wide by account/chat/message identity.
    // Keep these concurrent parameterized cases independent of each other.
    let messageID: Int64 = kind == "photo" ? -123 : kind == "document" ? -125 : -126
    let captionEntities = MessageEntities.with {
      $0.entities = [.with { $0.type = .bold; $0.offset = 0; $0.length = 7 }]
    }
    let original = try await database.dbWriter.write { db -> InlineKit.Message in
      try transaction.saveOptimisticState(db, currentUserId: accountID)
      try Chat(id: existingChatID, date: Date(), type: .thread, title: "Existing", spaceId: 5).save(db)
      var message = Message(
        messageId: messageID, randomId: -messageID, fromId: accountID, date: Date(), text: "caption",
        peerUserId: nil, peerThreadId: reservedChatID, chatId: reservedChatID, out: true, status: .sending,
        transactionId: "queued-\(kind)", entities: captionEntities
      )
      switch kind {
        case "photo":
          try Photo(id: 1, photoId: -42, format: .jpeg).insert(db)
          try PhotoSize(id: 1, photoId: 1, localPath: "pending-photo.jpg").insert(db)
          message.photoId = -42
        case "document":
          try Document(id: 1, documentId: -52, date: Date(), fileName: "pending.pdf", mimeType: "application/pdf",
                       size: 42, localPath: "pending.pdf").insert(db)
          message.documentId = -52
        default:
          message.setVoiceContent(.with {
            $0.voiceID = -63
            $0.localRelativePath = "pending-voice.m4a"
            $0.mimeType = "audio/mp4"
            $0.duration = 3
          })
      }
      try message.saveMessage(db)
      var plain = Message(
        messageId: -124, randomId: 124, fromId: accountID, date: Date(), text: "Plain queued reply",
        peerUserId: nil, peerThreadId: reservedChatID, chatId: reservedChatID, out: true, status: .sending
      )
      try plain.saveMessage(db)
      return try #require(try Message.fetchOne(db, key: ["messageId": messageID, "chatId": reservedChatID]))
    }

    let unsentTexts = try await database.dbWriter.write { db in
      try CreateSubthreadTransaction.removeShell(db, chatId: reservedChatID, redirectingTo: existingChatID)
    }
    #expect(unsentTexts == ["Plain queued reply"])
    let recovered = try await database.reader.read { db in
      try #require(try FullMessage.queryRequest(currentUserId: accountID)
        .filter(Column("chatId") == existingChatID && Column("messageId") == messageID).fetchOne(db))
    }
    #expect(recovered.message.globalId == original.globalId)
    #expect(recovered.message.randomId == original.randomId)
    #expect(recovered.message.status == .failed)
    #expect(recovered.message.chatId == existingChatID)
    #expect(recovered.message.peerThreadId == existingChatID)
    #expect(recovered.message.peerUserId == nil)
    #expect(recovered.message.text == original.text)
    #expect(recovered.message.entities == original.entities)
    #expect(recovered.message.transactionId == original.transactionId)
    let media = FailedMessageResender.mediaItems(for: recovered)
    #expect(media.count == 1)
    #expect(media.first?.getLocalPath() == (kind == "photo" ? "pending-photo.jpg" : kind == "document" ? "pending.pdf" : "pending-voice.m4a"))

    let resolver = ChatTransactionBlockerResolver(database: database)
    #expect(await resolver.state(for: .chatCreated(chatId: reservedChatID)) == .failed)
    #expect(await resolver.state(for: .chatCreated(chatId: existingChatID)) == .satisfied)
    var retry: TransactionSendMessage?
    try await FailedMessageResender.resend(recovered, database: database, auth: auth.handle) {
      retry = $0
      // Inspect admission without sending or replacing the recoverable row.
      return false
    }
    #expect(retry?.peerId == .thread(id: existingChatID))
    #expect(retry?.chatId == existingChatID)
    #expect(retry?.attachments.first?.media.getLocalPath() == media.first?.getLocalPath())
  }

  @Test("redirect merges remaining draft text, formatting and attachments without clearing the target draft")
  func redirectPreservesBothComposerDrafts() throws {
    let database = try makeDatabase()
    let drafts = Drafts2(database: database)
    let source = Peer.thread(id: reservedChatID)
    let target = Peer.thread(id: existingChatID)
    let sourceText = "draft 🦜"
    let sourceRevision = drafts.updateText(peer: source, text: sourceText)
    drafts.updateEntities(peer: source, entities: .with {
      $0.entities = [.with { $0.type = .bold; $0.offset = 0; $0.length = 5 }]
    }, forRevision: sourceRevision)
    let targetRevision = drafts.updateText(peer: target, text: "older")
    drafts.updateEntities(peer: target, entities: .with {
      $0.entities = [.with { $0.type = .italic; $0.offset = 0; $0.length = 5 }]
    }, forRevision: targetRevision)
    drafts.appendAttachment(peer: source, media: .voice(.with {
      $0.voiceID = -63; $0.localRelativePath = "pending-voice.m4a"
    }))
    drafts.appendAttachment(peer: target, media: .document(DocumentInfo(document: Document(
      id: 1, documentId: -52, date: Date(), fileName: "pending.pdf", mimeType: "application/pdf",
      size: 42, localPath: "pending.pdf"
    ))))

    CreateSubthreadTransaction.moveDraft(from: reservedChatID, to: existingChatID, drafts: drafts)
    let merged = try #require(drafts.load(peer: target))
    #expect(merged.text == "draft 🦜\n\nolder")
    #expect(merged.attachments.map { $0.media.getLocalPath() } == ["pending.pdf", "pending-voice.m4a"])
    #expect(merged.entities?.entities.map(\.offset) == [0, Int64(sourceText.utf16.count + 2)])
    #expect(drafts.load(peer: source)?.isEmpty ?? true)

    // A retried create result must not duplicate the recovered composer content.
    CreateSubthreadTransaction.moveDraft(from: reservedChatID, to: existingChatID, drafts: drafts)
    #expect(drafts.load(peer: target)?.text == merged.text)
    #expect(drafts.load(peer: target)?.attachments.map(\.id) == merged.attachments.map(\.id))
  }

  @Test("a colliding target identity never replaces another message")
  func redirectCollisionRollsBackWithoutLosingEitherMessage() async throws {
    let database = try makeDatabase()
    try await database.dbWriter.write { db in
      try transaction.saveOptimisticState(db, currentUserId: accountID)
      try Chat(id: existingChatID, date: Date(), type: .thread, title: "Existing", spaceId: 5).save(db)
      for chatId in [reservedChatID, existingChatID] {
        var message = Message(
          messageId: -123, randomId: chatId, fromId: accountID, date: Date(), text: "Message \(chatId)",
          peerUserId: nil, peerThreadId: chatId, chatId: chatId, out: true, status: .sending
        )
        message.setVoiceContent(.with { $0.voiceID = -63; $0.localRelativePath = "pending-voice.m4a" })
        try message.saveMessage(db)
      }
    }
    await #expect(throws: (any Error).self) {
      try await database.dbWriter.write { db in
        try CreateSubthreadTransaction.removeShell(db, chatId: reservedChatID, redirectingTo: existingChatID)
      }
    }
    let retained = try await database.reader.read { db in
      try Message.order(Message.Columns.chatId).fetchAll(db)
    }
    #expect(retained.map(\.text) == ["Message 70", "Message 80"])
    #expect(retained.allSatisfy { $0.status == .sending })
    #expect(try await database.reader.read { db in try Chat.fetchOne(db, key: reservedChatID) } != nil)
  }
}
