import Foundation
import GRDB
import Testing

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

  @Test("losing the race removes the shell, fails its dependents and keeps what was written")
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
    }
    drafts.updateText(peer: .thread(id: reservedChatID), text: "Still typing")
    drafts.updateText(peer: .thread(id: existingChatID), text: "Older draft")

    let unsent = try await database.dbWriter.write { db in
      try CreateSubthreadTransaction.removeShell(db, chatId: reservedChatID)
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

    #expect(drafts.load(peer: .thread(id: existingChatID))?.text == "First reply\n\nStill typing\n\nOlder draft")
    #expect(drafts.load(peer: .thread(id: reservedChatID))?.text ?? "" == "")
  }
}
