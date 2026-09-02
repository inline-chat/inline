import Combine
import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Explicit Ack cursor")
struct AcknowledgementTests {
  @Test func revisionedCursorMovesBothDirectionsClearsReactivatesAndSurvivesDeletion() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try InlineKit.User(id: 1, email: nil, firstName: "Actor").insert(db)
      try InlineKit.User(id: 2, email: nil, firstName: "Other actor").insert(db)
      try InlineKit.Chat(id: 100, date: Date(), type: .thread, title: "Test", spaceId: nil).insert(db)
      for id: Int64 in [10, 12] {
        var message = InlineKit.Message(
          messageId: id,
          fromId: 2,
          date: Date(),
          text: "Target",
          peerUserId: nil,
          peerThreadId: 100,
          chatId: 100
        )
        try message.saveMessage(db)
      }

      func cursor(
        _ user: Int64,
        _ maxId: Int64,
        revision: Int64,
        cleared: Bool = false
      ) -> InlineProtocol.ChatAcknowledgement {
        .with {
          $0.chatID = 100
          $0.userID = user
          $0.maxID = maxId
          $0.revision = revision
          $0.cleared = cleared
        }
      }

      #expect(try Acknowledgement.save(db, cursor: cursor(1, 10, revision: 1)) == [10])
      #expect(try Acknowledgement.save(db, cursor: cursor(1, 12, revision: 2)) == [10, 12])
      #expect(try Acknowledgement.save(db, cursor: cursor(1, 10, revision: 3)) == [10, 12])
      #expect(try Acknowledgement.save(db, cursor: cursor(1, 10, revision: 1)).isEmpty)
      #expect(try Acknowledgement.save(db, cursor: cursor(1, 12, revision: 2)).isEmpty)
      #expect(try Acknowledgement.save(db, cursor: cursor(1, 12, revision: 4)) == [10, 12])

      #expect(try Acknowledgement.save(db, cursor: cursor(1, 12, revision: 5, cleared: true)) == [12])
      var rows = try FullMessage.queryRequest()
        .filter(InlineKit.Message.Columns.chatId == 100)
        .fetchAll(db)
      let clearedMessage = try #require(rows.first { $0.message.messageId == 12 })
      #expect(clearedMessage.acknowledgementActors.isEmpty)
      #expect(clearedMessage.acknowledgementState(for: 1)?.cleared == true)
      #expect(clearedMessage.acknowledgementAction(currentUserId: 1) == AcknowledgementAction(
        clear: false,
        expectedRevision: 5
      ))

      // Reordered active state cannot resurrect the cleared marker.
      #expect(try Acknowledgement.save(db, cursor: cursor(1, 12, revision: 4)).isEmpty)
      #expect(try Acknowledgement.save(db, cursor: cursor(1, 12, revision: 6)) == [12])
      #expect(try Acknowledgement.save(db, cursor: cursor(1, 12, revision: 5, cleared: true)).isEmpty)

      try Acknowledgement.save(db, cursor: cursor(2, 10, revision: 7))
      rows = try FullMessage.queryRequest()
        .filter(InlineKit.Message.Columns.chatId == 100)
        .fetchAll(db)
      #expect(rows.first { $0.message.messageId == 10 }?.acknowledgementActors.map(\.acknowledgement.userId) == [2])
      #expect(rows.first { $0.message.messageId == 12 }?.acknowledgementActors.map(\.acknowledgement.userId) == [1])
      #expect(rows.first { $0.message.messageId == 10 }?.acknowledgementAttributionLabel
        == "Ack by Other actor")
      #expect(rows.first { $0.message.messageId == 12 }?.acknowledgementAttributionLabel
        == "Ack by Actor")

      try InlineKit.Message
        .filter(InlineKit.Message.Columns.chatId == 100)
        .filter(InlineKit.Message.Columns.messageId == 12)
        .deleteAll(db)
      let actor = try #require(try Acknowledgement.filter(Acknowledgement.Columns.userId == 1).fetchOne(db))
      #expect(actor.maxId == 12)
      #expect(actor.revision == 6)
      #expect(actor.cleared == false)
      #expect(try Acknowledgement.fetchCount(db) == 2)
    }
  }

  @Test func legacyRevisionZeroOnlyMovesForwardBeforeRevisionedState() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try InlineKit.User(id: 1, email: nil, firstName: "Actor").insert(db)
      try InlineKit.Chat(id: 100, date: Date(), type: .thread, title: "Test", spaceId: nil).insert(db)
      func cursor(_ maxId: Int64, revision: Int64 = 0) -> InlineProtocol.ChatAcknowledgement {
        .with { $0.chatID = 100; $0.userID = 1; $0.maxID = maxId; $0.revision = revision }
      }
      #expect(try Acknowledgement.save(db, cursor: cursor(10)) == [10])
      #expect(try Acknowledgement.save(db, cursor: cursor(10)).isEmpty)
      #expect(try Acknowledgement.save(db, cursor: cursor(12)) == [10, 12])
      #expect(try Acknowledgement.save(db, cursor: cursor(14, revision: 1)) == [12, 14])
      #expect(try Acknowledgement.save(db, cursor: cursor(16)).isEmpty)
    }
  }

  @Test func missingChatRejectsCursorInsteadOfAdvancingSyncState() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      let cursor = InlineProtocol.ChatAcknowledgement.with {
        $0.chatID = 100
        $0.userID = 1
        $0.maxID = 10
        $0.revision = 1
      }
      #expect(throws: AcknowledgementPersistenceError.missingChat(100)) {
        try Acknowledgement.save(db, cursor: cursor)
      }
    }
  }

  @Test func chatOpenPersistsActiveAndClearedCursorSnapshots() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { db in
      var chat = InlineProtocol.Chat()
      chat.id = 100
      chat.date = 1
      chat.title = "Test"
      chat.peerID = .with { $0.chat.chatID = 100 }
      chat.acknowledgements.cursors = [
        .with {
          $0.chatID = 100
          $0.userID = 1
          $0.maxID = 10
          $0.revision = 7
          $0.user = .with {
            $0.id = 1
            $0.firstName = "Actor"
          }
        },
        .with {
          $0.chatID = 100
          $0.userID = 2
          $0.maxID = 12
          $0.revision = 8
          $0.cleared = true
        },
      ]

      var dialog = InlineProtocol.Dialog()
      dialog.peer = chat.peerID
      dialog.chatID = chat.id

      var update = InlineProtocol.UpdateChatOpen()
      update.chat = chat
      update.dialog = dialog
      try update.apply(db)

      let active = try #require(try Acknowledgement
        .filter(Acknowledgement.Columns.chatId == 100 && Acknowledgement.Columns.userId == 1)
        .fetchOne(db))
      #expect(active.maxId == 10)
      #expect(active.revision == 7)
      #expect(!active.cleared)
      #expect(try User.fetchOne(db, id: 1)?.firstName == "Actor")

      let cleared = try #require(try Acknowledgement
        .filter(Acknowledgement.Columns.chatId == 100 && Acknowledgement.Columns.userId == 2)
        .fetchOne(db))
      #expect(cleared.maxId == 12)
      #expect(cleared.revision == 8)
      #expect(cleared.cleared)
    }
  }

  @Test func actionRejectsOwnAndUnsendableMessages() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try InlineKit.User(id: 1, email: nil, firstName: "Actor").insert(db)
      try InlineKit.Chat(id: 100, date: Date(), type: .thread, title: "Test", spaceId: nil).insert(db)
      var own = InlineKit.Message(
        messageId: 10,
        fromId: 1,
        date: Date(),
        text: "Own",
        peerUserId: nil,
        peerThreadId: 100,
        chatId: 100
      )
      try own.saveMessage(db)
      let fullOwn = try #require(try FullMessage.queryRequest().fetchOne(db))
      #expect(fullOwn.acknowledgementAction(currentUserId: 1) == nil)

      func fullMessage(_ message: InlineKit.Message) -> FullMessage {
        FullMessage(
          senderInfo: nil,
          message: message,
          reactions: [],
          repliedToMessage: nil,
          attachments: []
        )
      }

      own.fromId = 2
      own.status = .sending
      #expect(fullMessage(own).acknowledgementAction(currentUserId: 1) == nil)
      own.status = .failed
      #expect(fullMessage(own).acknowledgementAction(currentUserId: 1) == nil)
    }
  }

  @Test func coldThreadHistoryHydratesCursorBeforeFirstProjection() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      var response = InlineProtocol.GetChatHistoryResult()
      response.messages = [.with {
        $0.id = 10
        $0.chatID = 100
        $0.peerID = .with { $0.chat.chatID = 100 }
        $0.fromID = 2
        $0.date = 1
        $0.message = "Cold thread"
      }]
      response.acknowledgements.cursors = [.with {
        $0.chatID = 100; $0.userID = 1; $0.maxID = 10; $0.revision = 7
        $0.user = .with { $0.id = 1; $0.firstName = "Actor" }
      }]
      #expect(try InlineKit.Chat.fetchCount(db) == 0)
      try GetChatHistoryTransaction.apply(
        response,
        context: GetChatHistoryTransaction(peer: .thread(id: 100)).context,
        db: db
      )
      let firstFrame = try #require(try FullMessage.queryRequest().fetchOne(db))
      #expect(firstFrame.acknowledgementActors.map(\.acknowledgement.userId) == [1])
      #expect(firstFrame.acknowledgementActors.first?.userInfo?.user.firstName == "Actor")
    }
  }

  @Test @MainActor
  func everyEligibleMessageCanMoveTheAckEvenWhenTheTargetIsOutsideTheLoadedPage() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    try queue.write { db in
      try InlineKit.User(id: 2, email: nil, firstName: "Sender").insert(db)
      try InlineKit.Chat(id: 100, date: Date(), type: .thread, title: "Test", spaceId: nil).insert(db)
      for id: Int64 in [10, 12, 14] {
        var message = InlineKit.Message(
          messageId: id, fromId: 2, date: Date(), text: "Target",
          peerUserId: nil, peerThreadId: 100, chatId: 100
        )
        try message.saveMessage(db)
      }
      for cleared in [false, true] {
        let cursor = InlineProtocol.ChatAcknowledgement.with {
          $0.chatID = 100; $0.userID = 1; $0.maxID = 12
          $0.revision = cleared ? 2 : 1; $0.cleared = cleared
        }
        try Acknowledgement.save(db, cursor: cursor)
        let old = try #require(try FullMessage.queryRequest(currentUserId: 1)
          .filter(InlineKit.Message.Columns.messageId == 10).fetchOne(db))
        #expect(old.acknowledgementActors.isEmpty)
        #expect(old.acknowledgementAction(currentUserId: 1) == AcknowledgementAction(
          clear: false,
          expectedRevision: cleared ? 2 : 1
        ))
        let target = try #require(try FullMessage.queryRequest(currentUserId: 1)
          .filter(InlineKit.Message.Columns.messageId == 12).fetchOne(db))
        #expect(target.acknowledgementAction(currentUserId: 1) == AcknowledgementAction(
          clear: !cleared,
          expectedRevision: cleared ? 2 : 1
        ))
        let later = try #require(try FullMessage.queryRequest(currentUserId: 1)
          .filter(InlineKit.Message.Columns.messageId == 14).fetchOne(db))
        #expect(later.acknowledgementAction(currentUserId: 1) == AcknowledgementAction(
          clear: false,
          expectedRevision: cleared ? 2 : 1
        ))
      }
    }
    let model = MessagesProgressiveViewModel(
      peer: .thread(id: 100), database: database,
      publisher: MessagesPublisher(database: database), currentUserId: 1
    )
    let old = try #require(model.messages.first { $0.message.messageId == 10 })
    #expect(old.currentUserAcknowledgement?.userId == 1)
    #expect(old.acknowledgementAction(currentUserId: 1) == AcknowledgementAction(
      clear: false,
      expectedRevision: 2
    ))
  }

  @Test @MainActor
  func cursorPublicationUpdatesLoadedRowsWithoutAWorkingDatabase() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let publisher = MessagesPublisher(database: database)
    let peer: InlineKit.Peer = .user(id: 2)
    #if os(iOS)
    let active = publisher.activateChat(peer: peer)
    defer { publisher.deactivateChat(active) }
    #endif
    let rows = [Int64(10), 11, 12, 14].map { id in
      FullMessage(
        senderInfo: nil,
        message: InlineKit.Message(messageId: id, fromId: 2, date: Date(), text: "Target",
          peerUserId: 2, peerThreadId: nil, chatId: 100),
        reactions: [], repliedToMessage: nil, attachments: []
      )
    }
    let model = MessagesProgressiveViewModel(
      peer: peer,
      initialState: .init(messages: rows, loadedWindowMetadata: .init(messages: rows, holes: [])),
      database: database, publisher: publisher, currentUserId: 1
    )
    defer { model.dispose() }
    var updatedIDs: [[Int64]] = []
    model.observe { change in
      if case let .updated(messages, _, _) = change { updatedIDs.append(messages.map(\.message.messageId)) }
    }
    try queue.close()
    func publish(_ maxId: Int64, revision: Int64, cleared: Bool = false) {
      publisher.acknowledgementsChanged([
        FullAcknowledgement(acknowledgement: .init(
          chatId: 100, userId: 1, maxId: maxId, revision: revision, cleared: cleared
        )),
      ], peer: peer, animated: true)
    }
    publish(10, revision: 1)
    #expect(model.messages[0].acknowledgementActors.count == 1)
    publish(12, revision: 2)
    #expect(model.messages[0].acknowledgementActors.isEmpty)
    #expect(model.messages[0].acknowledgementAction(currentUserId: 1)?.expectedRevision == 2)
    #expect(model.messages[1].acknowledgementAction(currentUserId: 1)?.expectedRevision == 2)
    #expect(model.messages[2].acknowledgementActors.count == 1)
    #expect(model.messages[2].acknowledgementAction(currentUserId: 1) == AcknowledgementAction(
      clear: true,
      expectedRevision: 2
    ))
    #expect(model.messages[3].acknowledgementAction(currentUserId: 1)?.expectedRevision == 2)
    // The current actor's revision changes every eligible row action. Keep all
    // resident rows current so an immediate backward move cannot submit stale state.
    #expect(updatedIDs == [[10, 11, 12, 14], [10, 11, 12, 14]])
    publish(12, revision: 3, cleared: true)
    #expect(model.messages[2].acknowledgementActors.isEmpty)
    #expect(model.messages[2].acknowledgementAction(currentUserId: 1)?.expectedRevision == 3)
    #expect(model.messages[0].acknowledgementAction(currentUserId: 1)?.expectedRevision == 3)
  }

  @Test @MainActor
  func optimisticProjectionAppearsRollsBackAndCannotOverwriteConfirmation() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let publisher = MessagesPublisher(database: database)
    let peer: InlineKit.Peer = .user(id: 2)
    #if os(iOS)
    let active = publisher.activateChat(peer: peer)
    defer { publisher.deactivateChat(active) }
    #endif
    let rows = [Int64(10), 12, 14].map { id in
      FullMessage(
        senderInfo: nil,
        message: InlineKit.Message(messageId: id, fromId: 2, date: Date(), text: "Target",
          peerUserId: 2, peerThreadId: nil, chatId: 100),
        reactions: [], repliedToMessage: nil, attachments: []
      )
    }
    let model = MessagesProgressiveViewModel(
      peer: peer,
      initialState: .init(messages: rows, loadedWindowMetadata: .init(messages: rows, holes: [])),
      database: database,
      publisher: publisher,
      currentUserId: 1
    )
    defer { model.dispose() }

    func cursor(_ maxId: Int64, revision: Int64, cleared: Bool = false) -> FullAcknowledgement {
      FullAcknowledgement(acknowledgement: .init(
        chatId: 100, userId: 1, maxId: maxId, revision: revision, cleared: cleared
      ))
    }
    func row(_ id: Int64) throws -> FullMessage {
      try #require(model.messages.first { $0.message.messageId == id })
    }

    let firstRequest = UUID()
    #expect(publisher.beginOptimisticAcknowledgement(
      requestId: firstRequest,
      chatId: 100,
      userId: 1,
      maxId: 12,
      cleared: false,
      peer: peer,
      animated: true
    ))
    #expect(try row(12).acknowledgementActors.map(\.acknowledgement.revision) == [-1])
    #expect(try row(12).acknowledgementLabel == "Sending your Ack")
    #expect(model.messages.allSatisfy { $0.acknowledgementAction(currentUserId: 1) == nil })
    #expect(!publisher.beginOptimisticAcknowledgement(
      requestId: UUID(),
      chatId: 100,
      userId: 1,
      maxId: 14,
      cleared: false,
      peer: peer,
      animated: true
    ))

    // A DB-backed row replacement cannot erase the one pending projection.
    publisher.messageUpdatedSync(message: rows[1].message, peer: peer, animated: false)
    #expect(try row(12).acknowledgementActors.map(\.acknowledgement.revision) == [-1])

    publisher.restoreOptimisticAcknowledgement(
      requestId: firstRequest,
      chatId: 100,
      userId: 1,
      previous: nil,
      peer: peer,
      animated: true
    )
    #expect(model.messages.allSatisfy { $0.acknowledgementActors.isEmpty })
    #expect(try row(10).acknowledgementAction(currentUserId: 1) != nil)

    let confirmed = cursor(10, revision: 7)
    publisher.acknowledgementsChanged([confirmed], peer: peer, animated: true)
    let clearRequest = UUID()
    #expect(publisher.beginOptimisticAcknowledgement(
      requestId: clearRequest,
      chatId: 100,
      userId: 1,
      maxId: 10,
      cleared: true,
      peer: peer,
      animated: true
    ))
    #expect(try row(10).acknowledgementActors.isEmpty)
    #expect(model.messages.allSatisfy { $0.acknowledgementAction(currentUserId: 1) == nil })
    publisher.restoreOptimisticAcknowledgement(
      requestId: clearRequest,
      chatId: 100,
      userId: 1,
      previous: confirmed,
      peer: peer,
      animated: true
    )
    #expect(try row(10).acknowledgementActors.map(\.acknowledgement.revision) == [7])

    let delayedRequest = UUID()
    #expect(publisher.beginOptimisticAcknowledgement(
      requestId: delayedRequest,
      chatId: 100,
      userId: 1,
      maxId: 12,
      cleared: false,
      peer: peer,
      animated: true
    ))
    publisher.acknowledgementsChanged([cursor(14, revision: 8)], peer: peer, animated: true)
    publisher.enrichOptimisticAcknowledgement(
      requestId: delayedRequest,
      chatId: 100,
      userId: 1,
      userInfo: .init(user: .init(id: 1, email: nil, firstName: "Actor"), profilePhotos: nil),
      peer: peer,
      animated: false
    )
    publisher.restoreOptimisticAcknowledgement(
      requestId: delayedRequest,
      chatId: 100,
      userId: 1,
      previous: confirmed,
      peer: peer,
      animated: true
    )
    #expect(try row(14).acknowledgementActors.map(\.acknowledgement.revision) == [8])
    #expect(try row(10).acknowledgementActors.isEmpty)
    publisher.acknowledgementsChanged([cursor(12, revision: 7)], peer: peer, animated: true)
    #expect(try row(14).acknowledgementActors.map(\.acknowledgement.revision) == [8])
    #expect(try row(12).acknowledgementActors.isEmpty)
  }

  @Test func transactionCapturesRollbackStateAndOptimisticIdentity() throws {
    var message = FullMessage(
      senderInfo: nil,
      message: InlineKit.Message(messageId: 12, fromId: 2, date: Date(), text: "Target",
        peerUserId: 2, peerThreadId: nil, chatId: 100),
      reactions: [], repliedToMessage: nil, attachments: []
    )
    message.currentUserAcknowledgement = .init(
      chatId: 100, userId: 1, maxId: 10, revision: 7, cleared: false
    )
    let requestId = UUID()
    let action = try #require(message.acknowledgementAction(currentUserId: 1))
    #expect(action == AcknowledgementAction(clear: false, expectedRevision: 7))
    let transaction = AcknowledgeMessagesTransaction(
      message: message,
      action: action,
      currentUserId: 1,
      optimisticRequestId: requestId
    )
    #expect(transaction.context.userId == 1)
    #expect(transaction.context.previousAcknowledgement?.maxId == 10)
    #expect(transaction.context.previousAcknowledgement?.revision == 7)
    #expect(transaction.context.optimisticRequestId == requestId)
    let restored = try JSONDecoder().decode(
      AcknowledgeMessagesTransaction.self,
      from: JSONEncoder().encode(transaction)
    )
    #expect(restored.context.previousAcknowledgement == transaction.context.previousAcknowledgement)
    #expect(restored.context.optimisticRequestId == requestId)
  }

  @Test @MainActor
  func replyThreadAnchorDoesNotDisplayOrReceiveAcknowledgements() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let publisher = MessagesPublisher(database: database)
    let parent: InlineKit.Peer = .thread(id: 100)
    let child: InlineKit.Peer = .thread(id: 200)
    #if os(iOS)
    let active = publisher.activateChat(peer: child)
    defer { publisher.deactivateChat(active) }
    #endif
    let cursor = FullAcknowledgement(acknowledgement: .init(chatId: 100, userId: 1, maxId: 10, revision: 1))
    var anchor = FullMessage(
      senderInfo: nil,
      message: InlineKit.Message(messageId: 10, fromId: 2, date: Date(), text: "Parent",
        peerUserId: nil, peerThreadId: 100, chatId: 100),
      reactions: [], repliedToMessage: nil, attachments: []
    )
    anchor.acknowledgements = [cursor]
    let model = MessagesProgressiveViewModel(
      peer: child,
      initialState: .init(messages: [], threadAnchor: anchor, loadedWindowMetadata: .init(messages: [], holes: [])),
      database: database, publisher: publisher, currentUserId: 1
    )
    defer { model.dispose() }
    var count = 0
    model.observe { _ in count += 1 }
    try queue.close()
    publisher.acknowledgementsChanged([cursor], peer: parent, animated: true)
    #expect(model.threadAnchor?.acknowledgementActors.isEmpty == true)
    #expect(count == 0)
  }

  @Test(arguments: [100, 1000], [CGFloat(28), CGFloat(40)])
  func largeCountsReserveLegibleMinimumWidth(count: Int, contentWidth: CGFloat) {
    let minimum = AcknowledgementLayout.pillWidth(actorCount: count)
    let width = max(contentWidth, minimum)
    let shown = AcknowledgementLayout.visibleAvatarCount(actorCount: count, width: width)
    let countSpace = width - AcknowledgementLayout.countOriginX(visibleAvatarCount: shown) - 2
    #expect(shown == 0)
    #expect(countSpace >= AcknowledgementLayout.countWidth(count))
  }

  @Test func compactAggregationUsesAvatarsThenTotalCount() {
    #expect(AcknowledgementLayout.visibleAvatarCount(actorCount: 1, width: 28) == 1)
    #expect(AcknowledgementLayout.visibleAvatarCount(actorCount: 2, width: 37) == 2)
    #expect(AcknowledgementLayout.visibleAvatarCount(actorCount: 3, width: 46) == 3)
    #expect(AcknowledgementLayout.visibleAvatarCount(actorCount: 4, width: 78) == 0)
    #expect(AcknowledgementLayout.visibleAvatarCount(actorCount: 4, width: 28) == 0)
    #expect(AcknowledgementLayout.visibleAvatarCount(actorCount: 2, width: 37, availableAvatarCount: 1) == 0)
    #expect(AcknowledgementLayout.visibleAvatarCount(actorCount: 3, width: 46, availableAvatarCount: 2) == 1)
    #expect(AcknowledgementLayout.pillWidth(actorCount: 1) == 28)
    #expect(AcknowledgementLayout.pillWidth(actorCount: 2) == 37)
    #expect(AcknowledgementLayout.pillWidth(actorCount: 3) == 46)
    #expect(AcknowledgementLayout.pillWidth(actorCount: 4) == 28)
    #expect(AcknowledgementLayout.avatarStride < AcknowledgementLayout.avatarSize)
  }

  @Test(arguments: ["Hello", "😀 Hello", "۱۲۳ Hello", "42 😀", "你好"])
  func ltr(_ text: String) { #expect(!AcknowledgementLayout.isRTL(text)) }

  @Test(arguments: ["سلام", "😀 سلام", "123 שלום", "مرحبا hello"])
  func rtl(_ text: String) { #expect(AcknowledgementLayout.isRTL(text)) }

  @Test func neutralDirectionUsesNativeFallback() {
    #expect(AcknowledgementLayout.isRTL("😀 123", fallback: true))
    #expect(!AcknowledgementLayout.isRTL("😀 123", fallback: false))
  }
}
