import Combine
import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

private typealias Message = InlineKit.Message

// Each case owns real migrated SQL and deterministic held reads. Parallel
// MainActor fixture migrations can expire another case's watchdog and release
// its notification early, invalidating the ordering being measured.
@Suite("Message ID reconciliation", .serialized)
struct MessageIDReconciliationTests {
  private let chatId: Int64 = 71337
  private let userId: Int64 = 91337
  private let randomId: Int64 = 12345
  private let serverId: Int64 = 42

  private func database() throws -> (DatabaseQueue, AppDatabase) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    return (queue, try AppDatabase(queue))
  }

  // Resolve GRDB's synchronous overload outside async test bodies and
  // continuations so the complete update batch commits as one transaction.
  private func write<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T {
    try queue.write(body)
  }

  private func read<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T {
    try queue.read(body)
  }

  private func seed(_ db: Database) throws -> Message {
    try User(id: userId, email: nil, firstName: "Sender").insert(db)
    try Chat(id: chatId, date: Date(timeIntervalSince1970: 1), type: .thread,
             title: "Reconciliation", spaceId: nil).insert(db)
    var pending = Message(messageId: -randomId, randomId: randomId, fromId: userId,
                          date: Date(timeIntervalSince1970: 10), text: "pending text",
                          peerUserId: nil, peerThreadId: chatId, chatId: chatId,
                          out: true, status: .sending)
    pending = try pending.saveMessage(db)
    try Chat.updateLastMsgId(db, chatId: chatId, lastMsgId: pending.messageId, date: pending.date)
    return pending
  }

  private var confirmation: InlineProtocol.UpdateMessageId {
    .with { $0.randomID = randomId; $0.messageID = serverId }
  }

  private var newMessage: InlineProtocol.UpdateNewMessage {
    .with {
      $0.message = .with {
        $0.id = serverId
        $0.chatID = chatId
        $0.fromID = userId
        $0.date = 2
        $0.out = true
        $0.peerID = .with { $0.chat.chatID = chatId }
        $0.message = "canonical text"
      }
    }
  }

  @Test("opaque review token follows full projections and is invalidated by incremental attachment changes")
  func reviewTokenLifecycle() throws {
    let (queue, _) = try database()
    try write(queue) { db in
      _ = try seed(db)
      var source = newMessage.message
      source.rev = 1
      source.sourceSnapshot = "snapshot-v1"
      var saved = try Message.save(db, protocolMessage: source)
      #expect(saved.sourceSnapshot == "snapshot-v1")
      #expect(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(saved)).sourceSnapshot == "snapshot-v1")
      source.rev = 2
      source.sourceSnapshot = "snapshot-v2"
      saved = try Message.save(db, protocolMessage: source)
      #expect(saved.sourceSnapshot == "snapshot-v2")
      var stale = source
      stale.rev = 1
      stale.sourceSnapshot = "obsolete"
      #expect(try Message.save(db, protocolMessage: stale).sourceSnapshot == "snapshot-v2")
      try InlineProtocol.UpdateMessageAttachment.with {
        $0.chatID = chatId; $0.messageID = serverId; $0.attachment.id = 999
      }.apply(db, publishChanges: false)
      let invalidated = try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId])
      #expect(invalidated?.sourceSnapshot == nil)
      #expect(try Message.save(db, protocolMessage: source).sourceSnapshot == "snapshot-v2")
    }
  }

  @Test("user presentation fanout refreshes cached sender and child anchor without changing authored text")
  @MainActor
  func userPresentationFanout() async throws {
    let (queue, appDatabase) = try database()
    let anchor = try write(queue) { db in
      _ = try seed(db)
      return try #require(try FullMessage.queryRequest().filter(Message.Columns.chatId == chatId).fetchOne(db))
    }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
                                            publisher: publisher, currentUserId: userId)
    let child = MessagesProgressiveViewModel(peer: .thread(id: chatId + 1),
      initialState: .init(messages: [], threadAnchor: anchor, loadedWindowMetadata: .init(messages: [], holes: [])),
      database: appDatabase, publisher: publisher, currentUserId: userId)
    try write(queue) { db in
      var user = try #require(try User.fetchOne(db, id: userId))
      user.firstName = "Updated sender"
      try user.update(db)
    }
    await publisher.userPresentationUpdated(userId: userId)
    #expect(model.messages.first?.senderInfo?.user.firstName == "Updated sender")
    #expect(model.messages.first?.message.text == "pending text")
    #expect(child.threadAnchor?.senderInfo?.user.firstName == "Updated sender")
    model.dispose()
    child.dispose()
  }

  @Test("a held sender snapshot cannot undo a newer user or ACK publication", arguments: [false, true])
  @MainActor
  func delayedUserPresentationAcrossPublications(reconcile: Bool) async throws {
    let (queue, appDatabase) = try database()
    let oldURL = "https://cdn.inline.chat/avatar.jpg?token=old"
    let latestURL = "https://cdn.inline.chat/avatar.jpg?token=new"
    let pending = try write(queue) { db in
      let pending = try seed(db)
      var user = try #require(try User.fetchOne(db, id: userId))
      user.profileFileUniqueId = "same-photo"
      user.profileCdnUrl = oldURL
      try user.update(db)
      return pending
    }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
                                            publisher: publisher, currentUserId: userId)
    var emittedURLs: [String] = []
    let subscription = publisher.publisher.sink { update in
      if case let .userPresentation(info) = update { emittedURLs.append(info.user.profileCdnUrl ?? "missing") }
    }
    defer { subscription.cancel(); model.dispose() }
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let gate = ProjectionReadGate(started: continuation)
    let senderId = userId
    let delayed = Task { @MainActor in
      await publisher.userPresentationUpdated(userId: senderId, read: {
        let snapshot = try await queue.read { db in
          try User.userInfoQuery().filter(User.Columns.id == senderId).fetchOne(db)
        }
        await gate.pauseFirstRead()
        return snapshot
      })
    }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    try write(queue) { db in
      var user = try #require(try User.fetchOne(db, id: userId))
      user.firstName = "Latest sender"
      user.profileCdnUrl = latestURL
      try user.update(db)
      if reconcile {
        try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
        try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      }
    }
    if reconcile {
      await publisher.messageReconciled(messageId: serverId, chatId: chatId,
        replacingGlobalId: try #require(pending.globalId), peer: .thread(id: chatId))
    } else {
      await publisher.userPresentationUpdated(userId: userId)
    }
    #expect(model.messages.first?.senderInfo?.user.profileCdnUrl == latestURL)
    await gate.release()
    await delayed.value
    #expect(await gate.readCount == 2)
    #expect(!emittedURLs.isEmpty && emittedURLs.allSatisfy { $0 == latestURL })
    #expect(model.messages.count == 1)
    #expect(model.messages.first?.senderInfo?.user.firstName == "Latest sender")
    #expect(model.messages.first?.senderInfo?.user.profileCdnUrl == latestURL)
    #expect(model.messages.first?.message.text == (reconcile ? "canonical text" : "pending text"))
  }

  @Test("both update orders and replays converge to one authoritative message")
  func bothOrders() throws {
    for confirmedFirst in [true, false] {
      let (queue, _) = try database()
      try write(queue) { db in
        let pending = try seed(db)
        if confirmedFirst { try newMessage.apply(db, publishChanges: false, suppressNotifications: true) }
        let confirmedBefore = try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId])
        try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
        try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
        try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
        try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
        let rows = try Message.filter(Message.Columns.chatId == chatId).fetchAll(db)
        #expect(rows.count == 1)
        #expect(rows.first?.globalId == (confirmedBefore?.globalId ?? pending.globalId))
        #expect(rows.first?.messageId == serverId)
        #expect(rows.first?.text == "canonical text")
        #expect(rows.first?.status == .sent)
        #expect(rows.first?.randomId == nil)
        #expect(try Chat.fetchOne(db, id: chatId)?.lastMsgId == serverId)
      }
    }
  }

  @Test("a same-row legacy ACK clears random ID without deleting the sent row")
  func sameRow() throws {
    let (queue, _) = try database()
    try write(queue) { db in
      var pending = try seed(db)
      pending.messageId = serverId
      pending.status = .sent
      try pending.update(db)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      #expect(try Message.fetchCount(db) == 1)
      #expect(try Message.fetchOne(db, id: try #require(pending.globalId))?.randomId == nil)
    }
  }

  @Test("collision repairs the last pointer to the newest surviving message")
  func newerMessage() throws {
    let (queue, _) = try database()
    try write(queue) { db in
      _ = try seed(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      var newer = Message(messageId: 43, fromId: userId, date: Date(timeIntervalSince1970: 3),
                          text: "newer", peerUserId: nil, peerThreadId: chatId, chatId: chatId)
      try newer.saveMessage(db)
      #expect(try Chat.fetchOne(db, id: chatId)?.lastMsgId == -randomId)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      #expect(try Chat.fetchOne(db, id: chatId)?.lastMsgId == 43)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      #expect(try Chat.fetchOne(db, id: chatId)?.lastMsgId == 43)
    }
  }

  @Test("another sender's row cannot consume a pending message")
  func senderMismatch() throws {
    let (queue, _) = try database()
    try write(queue) { db in
      let pending = try seed(db)
      try User(id: userId + 1, email: nil, firstName: "Other").insert(db)
      var other = Message(messageId: serverId, fromId: userId + 1, date: Date(),
                          text: "other", peerUserId: nil, peerThreadId: chatId, chatId: chatId)
      try other.saveMessage(db)
      #expect(throws: (any Error).self) {
        try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      }
      #expect(try Message.fetchCount(db) == 2)
      #expect(try Message.fetchOne(db, id: try #require(pending.globalId))?.messageId == -randomId)
      #expect(try Chat.fetchOne(db, id: chatId)?.lastMsgId == -randomId)
    }
  }

  @Test("a failed removal rolls back local state and pointers")
  func rollback() throws {
    let (queue, _) = try database()
    try write(queue) { db in
      _ = try seed(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      try db.execute(sql: """
        CREATE TEMP TRIGGER reject_pending_removal BEFORE DELETE ON message
        WHEN OLD.messageId = -12345 BEGIN SELECT RAISE(ABORT, 'blocked pending removal'); END
        """)
      #expect(throws: (any Error).self) {
        try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      }
      #expect(try Message.fetchCount(db) == 2)
      #expect(try Chat.fetchOne(db, id: chatId)?.lastMsgId == -randomId)
      #expect(try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId])?.status == .sent)
    }
  }

  @Test("collision preserves recording and legacy transaction recovery state")
  func localState() throws {
    let (queue, _) = try database()
    try write(queue) { db in
      var pending = try seed(db)
      pending.transactionId = "legacy-upload"
      pending.contentPayload = .with { $0.voice = .with { $0.localRelativePath = "Voice/local.m4a" } }
      try pending.update(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      var confirmed = try #require(try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId]))
      confirmed.contentPayload = .with { $0.voice = .with { $0.voiceID = 42; $0.duration = 5 } }
      try confirmed.update(db)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      let confirmedGlobalId = try #require(confirmed.globalId)
      confirmed = try #require(try Message.fetchOne(db, id: confirmedGlobalId))
      #expect(confirmed.transactionId == "legacy-upload")
      #expect(confirmed.voiceContent?.localRelativePath == "Voice/local.m4a")
      #expect(confirmed.voiceContent?.voiceID == 42)
      #expect(confirmed.voiceContent?.duration == 5)
    }
  }

  @Test("committed publication replaces a loaded pending row even after silent history insertion")
  @MainActor
  func loadedCache() async throws {
    for loadedConfirmed in [false, true] {
      let (queue, appDatabase) = try database()
      try write(queue) { db in _ = try seed(db) }
      let publisher = MessagesPublisher(database: appDatabase)
      let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
                                              publisher: publisher, currentUserId: userId)
      #expect(model.messages.count == 1)
      try write(queue) { db in try newMessage.apply(db, publishChanges: false, suppressNotifications: true) }
      if loadedConfirmed {
        let confirmed = try read(queue) { db in
          try #require(try FullMessage.queryRequest().filter(Message.Columns.messageId == serverId).fetchOne(db))
        }
        publisher.messageAddedSync(fullMessage: confirmed, peer: .thread(id: chatId))
        #expect(model.messages.count == 2)
      }
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        do {
          try write(queue) { db in
            try confirmation.apply(db, currentUserId: userId) { messageId, chatId, oldId, peer in
              await publisher.messageReconciled(messageId: messageId, chatId: chatId, replacingGlobalId: oldId, peer: peer)
              continuation.resume()
            }
          }
        } catch { continuation.resume(throwing: error) }
      }
      #expect(model.messages.count == 1)
      #expect(model.messages.first?.message.messageId == serverId)
      #expect(model.messages.first?.message.text == "canonical text")
      #expect(model.messages.first?.message.status == .sent)
      model.dispose()
    }
  }
  @Test("ACK publication resolves the final transaction projection before its first emission")
  @MainActor
  func finalProjection() async throws {
    for deleted in [false, true] {
      let (queue, appDatabase) = try database()
      try write(queue) { db in _ = try seed(db) }
      let publisher = MessagesPublisher(database: appDatabase)
      let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
                                              publisher: publisher, currentUserId: userId)
      var firstProjection: [FullMessage]?
      model.observe { _ in if firstProjection == nil { firstProjection = model.messages } }
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        do {
          try write(queue) { db in
            try confirmation.apply(db, currentUserId: userId) { messageId, chatId, oldId, peer in
              await publisher.messageReconciled(messageId: messageId, chatId: chatId, replacingGlobalId: oldId, peer: peer)
              continuation.resume()
            }
            // Later durable updates in the same outer write must be visible on first publication.
            try newMessage.apply(db, publishChanges: true, suppressNotifications: true)
            if deleted {
              try InlineProtocol.UpdateDeleteMessages.with {
                $0.peerID.chat.chatID = chatId
                $0.messageIds = [serverId]
              }.apply(db, publishChanges: true)
            } else {
              try InlineProtocol.UpdateEditMessage.with {
                $0.message = newMessage.message
                $0.message.message = "final edit"
                $0.message.editDate = 3
                $0.message.rev = 1
              }.apply(db, publishChanges: true)
            }
          }
        } catch { continuation.resume(throwing: error) }
      }
      let projection = try #require(firstProjection)
      #expect(projection.count == (deleted ? 0 : 1))
      if !deleted { #expect(projection.first?.message.text == "final edit") }
      #expect(!projection.contains { $0.message.messageId < 0 })
      model.dispose()
    }
  }

  @Test("a delayed ACK projection cannot resurrect or overwrite a later separately committed delete or edit")
  @MainActor
  func delayedProjectionAcrossCommits() async throws {
    for deleted in [false, true] {
      let (queue, appDatabase) = try database()
      let pending = try write(queue) { db in try seed(db) }
      let publisher = MessagesPublisher(database: appDatabase)
      let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
                                              publisher: publisher, currentUserId: userId)
      try write(queue) { db in
        try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
        try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      }
      let (started, continuation) = AsyncStream<Void>.makeStream()
      let gate = ProjectionReadGate(started: continuation)
      let chatId = chatId, serverId = serverId
      let projection = Task { @MainActor in
        await publisher.messageReconciled(messageId: serverId, chatId: chatId,
          replacingGlobalId: try #require(pending.globalId), peer: .thread(id: chatId), read: {
            let snapshot = try await queue.read { db in
              try FullMessage.queryRequest().filter(Message.Columns.chatId == chatId && Message.Columns.messageId == serverId).fetchOne(db)
            }
            await gate.pauseFirstRead()
            return snapshot
          })
      }
      var iterator = started.makeAsyncIterator()
      _ = await iterator.next()
      if deleted {
        try write(queue) { db in
          try InlineProtocol.UpdateDeleteMessages.with {
            $0.peerID.chat.chatID = chatId; $0.messageIds = [serverId]
          }.apply(db, publishChanges: false)
        }
        publisher.messagesDeleted(messageIds: [serverId], peer: .thread(id: chatId))
      } else {
        let edited = try write(queue) { db in
          var edited = try #require(try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId]))
          edited.text = "later committed edit"
          edited.rev = 2
          try edited.update(db)
          return edited
        }
        publisher.messageUpdatedSync(message: edited, peer: .thread(id: chatId), animated: false)
      }
      await gate.release()
      try await projection.value
      #expect(await gate.readCount == 2)
      #expect(model.messages.count == (deleted ? 0 : 1))
      if !deleted { #expect(model.messages.first?.message.text == "later committed edit") }
      #expect(!model.messages.contains { $0.message.messageId < 0 })
      model.dispose()
    }
  }

  @Test("deleted ordinary-send receipt ACK removes the optimistic row without a phantom")
  @MainActor
  func deletedOrdinaryReceipt() async throws {
    let (queue, appDatabase) = try database()
    try write(queue) { db in _ = try seed(db) }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
                                            publisher: publisher, currentUserId: userId)
    var firstProjection: [FullMessage]?
    model.observe { _ in if firstProjection == nil { firstProjection = model.messages } }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      do {
        try write(queue) { db in
          try confirmation.apply(db, currentUserId: userId) { messageId, chatId, oldId, peer in
            await publisher.messageReconciled(messageId: messageId, chatId: chatId, replacingGlobalId: oldId, peer: peer)
            continuation.resume()
          }
          // A retained server receipt may refer to an intentionally deleted row.
          // This exact retry response contains no newMessage update.
          try InlineProtocol.UpdateDeleteMessages.with {
            $0.peerID.chat.chatID = chatId
            $0.messageIds = [serverId]
          }.apply(db, publishChanges: true)
        }
      } catch { continuation.resume(throwing: error) }
    }
    #expect(try read(queue) { try Message.fetchCount($0) } == 0)
    #expect(firstProjection?.isEmpty == true)
    #expect(model.messages.isEmpty)
    model.dispose()
  }

  @Test("outer rollback never publishes a successful identity change")
  @MainActor
  func rollbackPublication() async throws {
    enum Aborted: Error { case transaction }
    let (queue, _) = try database()
    try write(queue) { db in _ = try seed(db) }
    var published = false
    #expect(throws: Aborted.self) {
      try write(queue) { db in
        try confirmation.apply(db, currentUserId: userId) { _, _, _, _ in published = true }
        throw Aborted.transaction
      }
    }
    for _ in 0..<5 { await Task.yield() }
    #expect(!published)
    let pending = try read(queue) { try Message.fetchOne($0, key: ["chatId": chatId, "messageId": -randomId]) }
    #expect(pending != nil)
  }

  @Test("media paths and distinct attachments survive a pending/confirmed collision")
  func mediaPaths() throws {
    let (queue, _) = try database()
    try write(queue) { db in
      var pending = try seed(db)
      let localPhoto = try Photo(photoId: -21, format: .jpeg).insertAndFetch(db)
      let remotePhoto = try Photo(photoId: 21, format: .jpeg).insertAndFetch(db)
      let localPhotoId = try #require(localPhoto.id)
      let remotePhotoId = try #require(remotePhoto.id)
      let localSize = PhotoSize(photoId: localPhotoId, localPath: "local.jpg")
      let remoteSize = PhotoSize(photoId: remotePhotoId, cdnUrl: "https://media.invalid/confirmed.jpg")
      try localSize.insert(db); try remoteSize.insert(db)
      let localVideo = Video(videoId: -22, date: Date(), thumbnailPhotoId: localPhotoId, localPath: "local.mov")
      let remoteVideo = Video(videoId: 22, date: Date(), thumbnailPhotoId: remotePhotoId, cdnUrl: "https://media.invalid/confirmed.mov")
      try localVideo.insert(db); try remoteVideo.insert(db)
      let localDocument = Document(documentId: -23, date: Date(), localPath: "local.pdf", thumbnailPhotoId: localPhotoId)
      let remoteDocument = Document(documentId: 23, date: Date(), cdnUrl: "https://media.invalid/confirmed.pdf", thumbnailPhotoId: remotePhotoId)
      try localDocument.insert(db); try remoteDocument.insert(db)
      pending.photoId = -21; pending.videoId = -22; pending.documentId = -23
      try pending.update(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      var confirmed = try #require(try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId]))
      confirmed.photoId = 21; confirmed.videoId = 22; confirmed.documentId = 23
      try confirmed.update(db)
      for id in [Int64(31), 32] {
        let preview = UrlPreview(id: id, url: "https://example.invalid/\(id)", siteName: nil, title: nil,
                                 description: nil, photoId: nil, duration: nil)
        try preview.insert(db)
        let attachment = Attachment(messageId: pending.globalId, externalTaskId: nil, urlPreviewId: id, attachmentId: id)
        try attachment.insert(db)
      }
      let duplicate = Attachment(messageId: confirmed.globalId, externalTaskId: nil, urlPreviewId: 31, attachmentId: 131)
      try duplicate.insert(db)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      #expect(try PhotoSize.filter(PhotoSize.Columns.photoId == remotePhotoId).fetchOne(db)?.localPath == "local.jpg")
      #expect(try Video.filter(Video.Columns.videoId == 22).fetchOne(db)?.localPath == "local.mov")
      #expect(try Document.filter(Document.Columns.documentId == 23).fetchOne(db)?.localPath == "local.pdf")
      #expect(try Video.filter(Video.Columns.videoId == 22).fetchOne(db)?.cdnUrl == "https://media.invalid/confirmed.mov")
      let attachments = try Attachment.fetchAll(db)
      #expect(attachments.count == 2)
      #expect(attachments.allSatisfy { $0.messageId == confirmed.globalId })
      #expect(attachments.contains { $0.attachmentId == 131 })
    }
  }

  @Test("reconciliation reaches a child anchor before the child-peer gate")
  @MainActor
  func childAnchor() async throws {
    let (queue, appDatabase) = try database()
    let anchor = try write(queue) { db in
      _ = try seed(db)
      return try #require(try FullMessage.queryRequest().filter(Message.Columns.chatId == chatId).fetchOne(db))
    }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId + 1),
      initialState: .init(messages: [], threadAnchor: anchor, loadedWindowMetadata: .init(messages: [], holes: [])), database: appDatabase, publisher: publisher, currentUserId: userId)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      do {
        try write(queue) { db in
          try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
          try confirmation.apply(db, currentUserId: userId) { messageId, chatId, oldId, peer in
            await publisher.messageReconciled(messageId: messageId, chatId: chatId, replacingGlobalId: oldId, peer: peer)
            continuation.resume()
          }
        }
      } catch { continuation.resume(throwing: error) }
    }
    #expect(model.threadAnchor?.message.messageId == serverId)
    #expect(model.threadAnchor?.message.text == "canonical text")
    #expect(model.messages.isEmpty)
    model.dispose()
  }

  @Test("handled and unhandled ACKs preserve unrelated scheduled history reloads")
  @MainActor
  func preservesReload() async throws {
    for pendingLoaded in [false, true] {
      let (queue, appDatabase) = try database()
      let pending = try write(queue) { db in
        _ = try seed(db)
        return try #require(try FullMessage.queryRequest().filter(Message.Columns.chatId == chatId).fetchOne(db))
      }
      let publisher = MessagesPublisher(database: appDatabase)
      let model = MessagesProgressiveViewModel(peer: .thread(id: chatId),
        initialState: .init(messages: pendingLoaded ? [pending] : [], loadedWindowMetadata: .init(messages: [], holes: [])), database: appDatabase, publisher: publisher, currentUserId: userId)
      try write(queue) { db in
        try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
        var unrelated = Message(messageId: 43, fromId: userId, date: Date(timeIntervalSince1970: 3),
                                text: "unrelated silent insert", peerUserId: nil, peerThreadId: chatId, chatId: chatId)
        try unrelated.saveMessage(db)
        try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      }
      var loadedUnrelated = false
      model.observe { _ in loadedUnrelated = model.messages.contains { $0.message.messageId == 43 } }
      publisher.messagesReload(peer: .thread(id: chatId), animated: false)
      // Deliver in the same MainActor turn, before the reload task can begin its read.
      let confirmed = try read(queue) { db in
        try #require(try FullMessage.queryRequest().filter(Message.Columns.messageId == serverId).fetchOne(db))
      }
      publisher.publisher.send(.reconcile(confirmed, messageId: serverId, replacingGlobalId: pending.id, peer: .thread(id: chatId)))
      for _ in 0..<100 where !loadedUnrelated { try await Task.sleep(for: .milliseconds(10)) }
      #expect(loadedUnrelated)
      #expect(model.messages.contains { $0.message.messageId == 43 })
      model.dispose()
    }
  }

}

extension MessageIDReconciliationTests {
  @Test("held ordinary add/update snapshots respect later user/edit/delete and retire on rollback or cancellation",
        arguments: [false, true], ["user", "edit", "delete", "rollback", "cancel", "termination"])
  @MainActor
  func ordinaryRichReadFreshness(isAdd: Bool, kind: String) async throws {
    let (queue, appDatabase) = try database()
    let source = try write(queue) { db in
      _ = try seed(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      return try #require(try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId]))
    }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
      publisher: publisher, currentUserId: userId)
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let (userEvents, userContinuation) = AsyncStream<Void>.makeStream()
    let gate = ProjectionReadGate(started: continuation)
    let targetChat = chatId, targetMessage = serverId, senderId = userId
    var emitted: [FullMessage] = []
    let subscription = publisher.publisher.sink { event in
      switch event {
      case let .add(change): emitted += change.messages
      case let .update(change): emitted.append(change.message)
      case .userPresentation: userContinuation.yield(()); userContinuation.finish()
      default: break
      }
    }
    let watchdog = Task { try? await Task.sleep(for: .seconds(3)); userContinuation.finish() }
    defer { watchdog.cancel(); subscription.cancel(); model.dispose(); continuation.finish(); userContinuation.finish() }
    let reader: @Sendable () async throws -> FullMessage? = {
      let snapshot = try await queue.read { db in
        try FullMessage.queryRequest().filter(Message.Columns.chatId == targetChat && Message.Columns.messageId == targetMessage).fetchOne(db)
      }
      await gate.pauseFirstRead()
      return snapshot
    }
    let projection = Task { @MainActor in
      defer { continuation.finish() }
      if isAdd { await publisher.messageAdded(message: source, peer: .thread(id: targetChat), read: reader) }
      else { await publisher.messageUpdated(message: source, peer: .thread(id: targetChat), animated: false, read: reader) }
    }
    var starts = started.makeAsyncIterator()
    _ = await starts.next()
    switch kind {
    case "user":
      try write(queue) { db in
        _ = try User.save(db, user: .with {
          $0.id = senderId; $0.firstName = "Latest sender"; $0.min = true
          $0.profilePhoto.cdnURL = "https://cdn.inline.chat/latest.jpg"
        }, publisher: publisher)
      }
      var users = userEvents.makeAsyncIterator()
      _ = await users.next()
    case "edit":
      let edited = try write(queue) { db in
        var edited = source
        edited.text = "Latest committed edit"
        edited.rev = 2
        try edited.update(db)
        return edited
      }
      publisher.messageUpdatedSync(message: edited, peer: .thread(id: targetChat), animated: false)
    case "delete":
      try write(queue) { db in
        try Chat.filter(Chat.Columns.id == targetChat).updateAll(db, Chat.Columns.lastMsgId.set(to: nil))
        try Message.filter(Message.Columns.chatId == targetChat && Message.Columns.messageId == targetMessage).deleteAll(db)
      }
      publisher.messagesDeleted(messageIds: [targetMessage], peer: .thread(id: targetChat))
    case "rollback":
      enum Rollback: Error { case requested }
      do {
        try write(queue) { db in
          var edited = source
          edited.text = "Uncommitted edit"
          try edited.update(db)
          var changes = MessageProjectionDependencies()
          changes.include(edited)
          changes.publishAfterCommit(db, publisher: publisher)
          throw Rollback.requested
        }
      } catch Rollback.requested {}
    case "cancel": projection.cancel()
    case "termination": publisher.closeAdmissionForTermination()
    default: Issue.record("Unknown held-read case")
    }
    await gate.release()
    await projection.value
    await publisher.waitForAdmittedDatabaseReadsForTermination()
    #expect(await gate.readCount == (["user", "edit", "delete"].contains(kind) ? 2 : 1))
    if kind == "delete" || kind == "cancel" || kind == "termination" { #expect(emitted.isEmpty) }
    else {
      let first = try #require(emitted.first)
      if kind == "user" {
        #expect(first.senderInfo?.user.displayName == "Latest sender")
        #expect(emitted.allSatisfy { $0.senderInfo?.user.profileCdnUrl == "https://cdn.inline.chat/latest.jpg" })
      } else if kind == "edit" {
        #expect(first.message.text == "Latest committed edit")
        #expect(emitted.allSatisfy { $0.message.rev == 2 })
      } else { #expect(first.message.text == source.text) }
    }
    if kind == "delete" { #expect(model.messages.isEmpty) }
    let dependencies = MessageProjectionDependencies(identities: [.message(chatId: targetChat, messageId: targetMessage)])
    publisher.projectionRowsCommitted(dependencies)
    #expect(!publisher.hasActiveProjectionChanges(dependencies))
  }

  @Test("a committed user refresh updates resident raw, reaction, ACK and task joins in every loaded chat")
  @MainActor
  func residentSharedUserPresentation() async throws {
    let (queue, appDatabase) = try database()
    let relatedId = userId + 1
    let initial = try write(queue) { db in
      _ = try seed(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      try User(id: relatedId, email: nil, firstName: "Old related").insert(db)
      var source = try #require(try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId]))
      source.forwardFromUserId = relatedId
      source.forwardFromPeerUserId = relatedId
      try source.update(db)
      try Reaction(id: 700, messageId: serverId, userId: relatedId, emoji: "👍", date: Date(), chatId: chatId).insert(db)
      try Acknowledgement(chatId: chatId, userId: relatedId, maxId: serverId, revision: 1).insert(db)
      var task = ExternalTask(application: "linear", taskId: "task", status: .todo,
        assignedUserId: relatedId, url: nil, title: "Task", date: nil, number: "1")
      task.id = 800
      try task.insert(db)
      try Attachment(messageId: source.globalId, externalTaskId: 800, urlPreviewId: nil, attachmentId: 801).insert(db)
      return try #require(try FullMessage.queryRequest().filter(Message.Columns.chatId == chatId && Message.Columns.messageId == serverId).fetchOne(db))
    }
    // Missing optional decorations must be restored from their raw identities.
    var missing = initial
    missing.forwardFromPeerUserInfo = nil
    missing.forwardFromUserInfo = nil
    missing.reactions[0].userInfo = nil
    missing.acknowledgements?[0].userInfo = nil
    missing.attachments[0].userInfo = nil
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId),
      initialState: .init(messages: [missing], loadedWindowMetadata: .init(messages: [missing], holes: [])),
      database: appDatabase, publisher: publisher, currentUserId: userId)
    let child = MessagesProgressiveViewModel(peer: .thread(id: chatId + 1),
      initialState: .init(messages: [], threadAnchor: missing, loadedWindowMetadata: .init(messages: [], holes: [])),
      database: appDatabase, publisher: publisher, currentUserId: userId)
    let (committed, continuation) = AsyncStream<Void>.makeStream()
    let subscription = publisher.publisher.sink {
      if case let .userPresentation(info) = $0, info.id == relatedId { continuation.yield(()); continuation.finish() }
    }
    let watchdog = Task { try? await Task.sleep(for: .seconds(3)); continuation.finish() }
    defer { watchdog.cancel(); subscription.cancel(); model.dispose(); child.dispose(); continuation.finish() }
    try write(queue) { db in
      _ = try User.save(db, user: .with {
        $0.id = relatedId; $0.firstName = "Current related"; $0.min = true
        $0.profilePhoto.cdnURL = "https://cdn.inline.chat/current-avatar.jpg"
      }, publisher: publisher)
    }
    var events = committed.makeAsyncIterator()
    _ = await events.next()
    for refreshed in [try #require(model.messages.first), try #require(child.threadAnchor)] {
      #expect(refreshed.forwardFromUserInfo?.user.displayName == "Current related")
      #expect(refreshed.forwardFromPeerUserInfo?.user.displayName == "Current related")
      #expect(refreshed.reactions.first?.userInfo?.user.displayName == "Current related")
      if refreshed.acknowledgements != nil {
        #expect(refreshed.acknowledgements?.first?.userInfo?.user.displayName == "Current related")
      }
      #expect(refreshed.attachments.first?.userInfo?.user.displayName == "Current related")
      #expect(refreshed.message.text == initial.message.text)
      #expect(refreshed.message.rev == initial.message.rev)
    }
    #expect(model.messages.first?.acknowledgements?.first?.userInfo?.user.displayName == "Current related")
  }

  @Test("ordinary committed identity writes fence first emission before delayed delivery", arguments: [
    "save", "silentSave", "delete", "silentDelete", "ack", "cursor", "reaction", "deleteReaction",
  ], [false, true])
  @MainActor
  func ordinaryCommittedWriterBeforeActorDelivery(kind: String, rollback: Bool) async throws {
    let (queue, appDatabase) = try database()
    let initial = try write(queue) { db in
      _ = try seed(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      if kind != "ack" { try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in }) }
      if kind == "deleteReaction" {
        try Reaction(id: 888, messageId: serverId, userId: userId, emoji: "👍", date: Date(), chatId: chatId).insert(db)
      }
      return try #require(try FullMessage.queryRequest().filter(Message.Columns.chatId == chatId && Message.Columns.messageId == serverId).fetchOne(db))
    }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId),
      initialState: .init(messages: [initial], loadedWindowMetadata: .init(messages: [initial], holes: [])),
      database: appDatabase, publisher: publisher, currentUserId: userId)
    let (readStarted, readContinuation) = AsyncStream<Void>.makeStream()
    let readGate = ProjectionReadGate(started: readContinuation)
    let (deliveryStarted, deliveryContinuation) = AsyncStream<Void>.makeStream()
    let deliveryGate = ProjectionReadGate(started: deliveryContinuation)
    var emitted: [FullMessage?] = []
    let subscription = publisher.publisher.sink {
      if case let .reconcile(message, _, _, _) = $0 { emitted.append(message) }
    }
    let targetChat = chatId, targetMessage = serverId
    let replacingId = try #require(initial.message.globalId)
    let projection = Task { @MainActor in
      await publisher.messageReconciled(messageId: targetMessage, chatId: targetChat,
        replacingGlobalId: replacingId, peer: .thread(id: targetChat), read: {
          let snapshot = try await queue.read {
            try FullMessage.queryRequest().filter(Message.Columns.chatId == targetChat && Message.Columns.messageId == targetMessage).fetchOne($0)
          }
          await readGate.pauseFirstRead()
          return snapshot
        })
    }
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(3))
      readContinuation.finish(); deliveryContinuation.finish()
      await readGate.release(); await deliveryGate.release()
    }
    defer { watchdog.cancel(); subscription.cancel(); model.dispose(); readContinuation.finish(); deliveryContinuation.finish() }
    var reads = readStarted.makeAsyncIterator()
    _ = await reads.next()
    enum Rollback: Error { case requested }
    do {
      try write(queue) { db in
        let beforeNotification: @Sendable () async -> Void = { await deliveryGate.pauseFirstRead() }
        switch kind {
        case "save", "silentSave":
          var updated = initial.message
          updated.text = "after committed write"
          _ = try updated.saveMessage(db, publishChanges: kind == "save", publisher: publisher,
            beforeAsyncNotification: beforeNotification)
        case "delete", "silentDelete":
          try InlineProtocol.UpdateDeleteMessages.with {
            $0.peerID.chat.chatID = targetChat; $0.messageIds = [targetMessage]
          }.apply(db, publishChanges: kind == "delete", publisher: publisher, beforeAsyncNotification: beforeNotification)
        case "ack":
          try confirmation.apply(db, currentUserId: userId, publisher: publisher,
            beforeAsyncNotification: beforeNotification, publish: { messageId, chatId, globalId, peer in
              await publisher.messageReconciled(messageId: messageId, chatId: chatId, replacingGlobalId: globalId, peer: peer)
            })
          // The ACK signal must reflect the final outer transaction, not an
          // intermediate row captured before a later same-transaction edit.
          try Message.filter(Message.Columns.chatId == targetChat && Message.Columns.messageId == targetMessage)
            .updateAll(db, Message.Columns.text.set(to: "after committed write"))
        case "cursor":
          _ = try Acknowledgement.save(db, cursor: .with {
            $0.chatID = targetChat; $0.userID = userId; $0.maxID = targetMessage; $0.revision = 1
          }, publisher: publisher)
        case "reaction":
          _ = try Reaction.save(db, reaction: Reaction(id: 888, messageId: targetMessage, userId: userId,
            emoji: "👍", date: Date(), chatId: targetChat), publisher: publisher)
        case "deleteReaction":
          try InlineProtocol.UpdateDeleteReaction.with {
            $0.chatID = targetChat; $0.messageID = targetMessage; $0.userID = userId; $0.emoji = "👍"
          }.apply(db, publisher: publisher)
        default: Issue.record("Unexpected ordinary writer")
        }
        if rollback { throw Rollback.requested }
      }
    } catch Rollback.requested {}
    if !rollback, ["save", "delete", "ack"].contains(kind) {
      var deliveries = deliveryStarted.makeAsyncIterator()
      _ = await deliveries.next()
    }
    await readGate.release()
    await projection.value
    #expect(emitted.count == 1)
    let isDelete = kind == "delete" || kind == "silentDelete"
    let isTextChange = ["save", "silentSave", "ack"].contains(kind)
    let expected = rollback || !isTextChange && !isDelete ? initial.message.text : (isDelete ? nil : "after committed write")
    #expect(emitted.first.flatMap { $0 }?.message.text == expected)
    #expect(await readGate.readCount == (rollback ? 1 : 2))
    #expect(model.messages.first?.message.text == expected)
    #expect(model.messages.count == (!rollback && isDelete ? 0 : 1))
    if kind == "cursor" {
      #expect(emitted.first.flatMap { $0 }?.acknowledgements?.first?.acknowledgement.revision == (rollback ? nil : 1))
    } else if kind == "reaction" || kind == "deleteReaction" {
      let expectedCount = (kind == "reaction") != rollback ? 1 : 0
      #expect(emitted.first.flatMap { $0 }?.reactions.count == expectedCount)
    }
    await deliveryGate.release()
  }

  @Test("chat removal owners fence held ACK and ordinary reads before delayed deletion notification",
        arguments: ["helperAck", "helperAdd", "helperUpdate", "helperDMAck", "dialogAck", "dialogAdd", "dialogUpdate", "dialogAckPointer"],
        [false, true])
  @MainActor
  func chatRemovalBeforeActorDelivery(kind: String, rollback: Bool) async throws {
    let (queue, appDatabase) = try database()
    let initial = try write(queue) { db in
      _ = try seed(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      if kind == "helperDMAck" {
        try Chat.filter(Chat.Columns.id == chatId).updateAll(db,
          Chat.Columns.type.set(to: ChatType.privateChat.rawValue), Chat.Columns.peerUserId.set(to: userId))
        try Message.filter(Message.Columns.chatId == chatId && Message.Columns.messageId == serverId).updateAll(db,
          Message.Columns.peerThreadId.set(to: nil), Message.Columns.peerUserId.set(to: userId))
      }
      // The old dialog-delete owner fails on the real last-message FK too.
      // Other cases clear that pointer to isolate its stale-emission bypass.
      if kind.hasPrefix("dialog"), kind != "dialogAckPointer" {
        try Chat.filter(Chat.Columns.id == chatId).updateAll(db, Chat.Columns.lastMsgId.set(to: nil))
      }
      return try #require(try FullMessage.queryRequest()
        .filter(Message.Columns.chatId == chatId && Message.Columns.messageId == serverId).fetchOne(db))
    }
    let publisher = MessagesPublisher(database: appDatabase)
    let isAck = kind.contains("Ack"), isAdd = kind.contains("Add")
    let loaded = isAck ? [initial] : []
    let sourcePeer = initial.message.peerId
    let model = MessagesProgressiveViewModel(peer: sourcePeer,
      initialState: .init(messages: loaded, loadedWindowMetadata: .init(messages: loaded, holes: [])),
      database: appDatabase, publisher: publisher, currentUserId: userId)
    let (readStarted, readContinuation) = AsyncStream<Void>.makeStream()
    let readGate = ProjectionReadGate(started: readContinuation)
    let (deliveryStarted, deliveryContinuation) = AsyncStream<Void>.makeStream()
    let deliveryGate = ProjectionReadGate(started: deliveryContinuation)
    let (delivered, deliveredContinuation) = AsyncStream<Void>.makeStream()
    var emitted: [FullMessage?] = []
    let subscription = publisher.publisher.sink {
      switch $0 {
      case let .reconcile(message, _, _, _): emitted.append(message)
      case let .add(change): emitted += change.messages.map(Optional.some)
      case let .update(change): emitted.append(change.message)
      default: break
      }
    }
    let targetChat = chatId, targetMessage = serverId
    let source = initial.message
    let replacingId = try #require(source.globalId)
    let reader: @Sendable () async throws -> FullMessage? = {
      let snapshot = try await queue.read {
        try FullMessage.queryRequest().filter(Message.Columns.chatId == targetChat && Message.Columns.messageId == targetMessage).fetchOne($0)
      }
      await readGate.pauseFirstRead()
      return snapshot
    }
    let projection = Task { @MainActor in
      if isAck {
        await publisher.messageReconciled(messageId: targetMessage, chatId: targetChat,
          replacingGlobalId: replacingId, peer: sourcePeer, read: reader)
      } else if isAdd {
        await publisher.messageAdded(message: source, peer: sourcePeer, read: reader)
      } else {
        await publisher.messageUpdated(message: source, peer: sourcePeer, animated: false, read: reader)
      }
    }
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(3))
      readContinuation.finish(); deliveryContinuation.finish(); deliveredContinuation.finish()
      await readGate.release(); await deliveryGate.release()
    }
    defer {
      watchdog.cancel(); subscription.cancel(); model.dispose()
      readContinuation.finish(); deliveryContinuation.finish(); deliveredContinuation.finish()
      Task { await readGate.release(); await deliveryGate.release() }
    }
    var reads = readStarted.makeAsyncIterator()
    _ = await reads.next()
    enum Rollback: Error { case requested }
    do {
      try write(queue) { db in
        let beforeNotification: @Sendable () async -> Void = {
          await deliveryGate.pauseFirstRead()
          deliveredContinuation.yield(()); deliveredContinuation.finish()
        }
        if kind.hasPrefix("helper") {
          try deleteLocalChatData(db, chatId: targetChat, publisher: publisher, beforeAsyncNotification: beforeNotification)
        } else {
          try UpdateDialogOpenTransaction.applyDeletedChat(peer: .thread(id: targetChat), db: db,
            publisher: publisher, beforeAsyncNotification: beforeNotification)
        }
        if rollback { throw Rollback.requested }
      }
    } catch Rollback.requested {}
    if !rollback {
      var deliveries = deliveryStarted.makeAsyncIterator()
      _ = await deliveries.next()
    }
    await readGate.release()
    await projection.value
    #expect(await readGate.readCount == (rollback ? 1 : 2))
    if isAck {
      #expect(emitted.count == 1)
      #expect(emitted.first.flatMap { $0 }?.message.text == (rollback ? source.text : nil))
    } else {
      #expect(emitted.count == (rollback ? 1 : 0))
    }
    let expectedResidentCount = rollback && (isAck || isAdd) ? 1 : 0
    #expect(model.messages.count == expectedResidentCount)
    await deliveryGate.release()
    if !rollback {
      var deliveries = delivered.makeAsyncIterator()
      _ = await deliveries.next()
    }
    #expect(await deliveryGate.readCount == (rollback ? 0 : 1))
    #expect(model.messages.count == expectedResidentCount)
    let dependencies = MessageProjectionDependencies(identities: [.message(chatId: targetChat, messageId: targetMessage)])
    #expect(!publisher.hasActiveProjectionChanges(dependencies))
  }

  @Test("joined translation reaction and chat writers fence first rich projection",
        arguments: ["translation", "reactionDelete", "chatFullForward", "chatInfoForward", "chatDeleteForward", "chatDeleteParentForward",
                    "chatFullChild", "chatInfoChild", "chatCreateChild", "chatMoveChild", "chatMoveChildDestination",
                    "chatValidNoLast", "chatValidWithLast", "chatValidMissingLast", "chatEnsureMissingUser", "outsideWindowChild"],
        [false, true])
  @MainActor
  func joinedWriterBeforeActorDelivery(kind: String, rollback: Bool) async throws {
    let (queue, appDatabase) = try database()
    let relatedChatId = chatId + 10
    let missingUserId = userId + 10
    let ancestorChatId = chatId + 20
    let selectedId = kind == "chatMoveChildDestination" ? serverId + 1 : serverId
    let initial = try write(queue) { db in
      _ = try seed(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      if kind == "reactionDelete" {
        try Reaction(id: 888, messageId: serverId, userId: userId, emoji: "👍", date: Date(), chatId: chatId).insert(db)
      }
      if kind.hasPrefix("chat") || kind == "outsideWindowChild" {
        let isChild = kind.contains("Child")
        var second = initialMessage(id: serverId + 1, chat: chatId)
        _ = try second.saveMessage(db)
        if kind == "chatDeleteParentForward" {
          try Chat(id: ancestorChatId, date: Date(timeIntervalSince1970: 2), type: .thread,
            title: "Removed ancestor", spaceId: nil).insert(db)
          var ancestor = initialMessage(id: 1, chat: ancestorChatId)
          _ = try ancestor.saveMessage(db)
        }
        if kind != "chatCreateChild" {
          try Chat(id: relatedChatId, date: Date(timeIntervalSince1970: 2), type: .thread, title: "Old joined title",
            spaceId: nil, parentChatId: kind == "chatDeleteParentForward" ? ancestorChatId : (isChild ? chatId : nil),
            parentMessageId: kind == "chatDeleteParentForward" ? 1 : (isChild ? (kind == "outsideWindowChild" ? serverId + 1 : serverId) : nil)).insert(db)
        }
        if kind.contains("Forward") || kind.hasPrefix("chatValid") {
          try Message.filter(Message.Columns.chatId == chatId && Message.Columns.messageId == serverId)
            .updateAll(db, Message.Columns.forwardFromPeerThreadId.set(to: relatedChatId))
        }
        if kind == "chatEnsureMissingUser" {
          try Message.filter(Message.Columns.chatId == chatId && Message.Columns.messageId == serverId)
            .updateAll(db, Message.Columns.forwardFromUserId.set(to: missingUserId))
        }
        if kind == "chatValidWithLast" {
          var childMessage = initialMessage(id: 100, chat: relatedChatId)
          _ = try childMessage.saveMessage(db)
        }
      }
      return try #require(try FullMessage.queryRequest()
        .filter(Message.Columns.chatId == chatId && Message.Columns.messageId == selectedId).fetchOne(db))
    }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId),
      initialState: .init(messages: [initial], loadedWindowMetadata: .init(messages: [initial], holes: [])),
      database: appDatabase, publisher: publisher, currentUserId: userId)
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let gate = ProjectionReadGate(started: continuation)
    var emitted: [FullMessage?] = []
    let subscription = publisher.publisher.sink {
      if case let .reconcile(message, _, _, _) = $0 { emitted.append(message) }
    }
    let targetChat = chatId, targetMessage = selectedId, actorId = userId, originalAnchor = serverId
    let replacingId = try #require(initial.message.globalId)
    let projection = Task { @MainActor in
      await publisher.messageReconciled(messageId: targetMessage, chatId: targetChat,
        replacingGlobalId: replacingId, peer: .thread(id: targetChat), read: {
          let snapshot = try await queue.read {
            try FullMessage.queryRequest().filter(Message.Columns.chatId == targetChat && Message.Columns.messageId == targetMessage).fetchOne($0)
          }
          await gate.pauseFirstRead()
          return snapshot
        })
    }
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(3))
      continuation.finish(); await gate.release()
    }
    defer {
      watchdog.cancel(); subscription.cancel(); model.dispose(); continuation.finish()
      Task { await gate.release() }
    }
    var starts = started.makeAsyncIterator()
    _ = await starts.next()
    enum Rollback: Error { case requested }
    // Outside-window edits are separate real commits under the same parent.
    // Their anchor must not broaden into parent-wide invalidation.
    for iteration in 0..<(kind == "outsideWindowChild" ? 8 : 1) {
      do {
        try write(queue) { db in
          switch kind {
          case "translation":
            _ = try Translation.save(db, protocolTranslation: .with {
              $0.messageID = targetMessage; $0.translation = "Current translation"; $0.language = "fr"
              $0.date = 2; $0.msgRev = initial.message.rev
            }, chatId: targetChat, publisher: publisher)
          case "reactionDelete":
            try DeleteReactionTransaction(emoji: "👍", message: initial.message)
              .applyOptimisticRemoval(db, currentUserId: actorId, publisher: publisher)
          case "chatDeleteForward":
            try deleteLocalChatData(db, chatId: relatedChatId, publisher: publisher)
          case "chatDeleteParentForward":
            try deleteLocalChatData(db, chatId: ancestorChatId, publisher: publisher)
          case "chatInfoForward", "chatInfoChild":
            try InlineProtocol.UpdateChatInfo.with {
              $0.chatID = relatedChatId; $0.title = "Current joined title"
            }.apply(db, publisher: publisher)
          default:
            var chat = try Chat.fetchOne(db, id: relatedChatId) ?? Chat(id: relatedChatId,
              date: Date(timeIntervalSince1970: 2), type: .thread, title: nil, spaceId: nil,
              parentChatId: targetChat, parentMessageId: targetMessage)
            chat.title = "Current joined title"
            if kind.hasPrefix("chatMoveChild") { chat.parentMessageId = originalAnchor + 1 }
            if kind == "outsideWindowChild" {
              chat.parentChatId = targetChat; chat.parentMessageId = targetMessage + 1
              chat.title = "Outside window \(iteration)"
            }
            if kind == "chatEnsureMissingUser" {
              chat.type = .privateChat; chat.peerUserId = missingUserId
              try chat.saveWithValidLastMsg(db, publisher: publisher)
            } else if kind.hasPrefix("chatValid") {
              chat.lastMsgId = kind == "chatValidWithLast" ? 100 : (kind == "chatValidMissingLast" ? 101 : nil)
              try chat.saveWithValidLastMsg(db, publisher: publisher)
            } else {
              _ = try chat.saveFull(db, publisher: publisher)
            }
          }
          if rollback { throw Rollback.requested }
        }
      } catch Rollback.requested {}
    }
    await gate.release()
    await projection.value
    let first = try #require(emitted.first.flatMap { $0 })
    #expect(emitted.count == 1)
    #expect(await gate.readCount == (rollback || kind == "outsideWindowChild" ? 1 : 2))
    if kind == "translation" {
      #expect(first.translations.first?.translation == (rollback ? nil : "Current translation"))
    } else if kind == "reactionDelete" {
      #expect(first.reactions.count == (rollback ? 1 : 0))
    } else if kind == "chatEnsureMissingUser" {
      #expect(first.forwardFromUserInfo?.id == (rollback ? nil : missingUserId))
    } else if kind == "chatDeleteParentForward" {
      #expect(first.forwardFromChatInfo?.title == "Old joined title")
      #expect(first.forwardFromChatInfo?.parentChatId == (rollback ? ancestorChatId : nil))
    } else if kind.contains("Forward") || kind.hasPrefix("chatValid") {
      let expectedTitle = rollback ? "Old joined title" : (kind == "chatDeleteForward" ? nil : "Current joined title")
      #expect(first.forwardFromChatInfo?.title == expectedTitle)
    } else if kind == "chatCreateChild" {
      #expect(first.replyThread?.title == (rollback ? nil : "Current joined title"))
    } else if kind == "chatMoveChild" {
      #expect(first.replyThread?.title == (rollback ? "Old joined title" : nil))
      let moved = try read(queue) { db in
        try FullMessage.queryRequest().filter(Message.Columns.chatId == targetChat && Message.Columns.messageId == targetMessage + 1).fetchOne(db)
      }
      #expect(moved?.replyThread?.title == (rollback ? nil : "Current joined title"))
    } else if kind == "chatMoveChildDestination" {
      #expect(first.replyThread?.title == (rollback ? nil : "Current joined title"))
      let oldAnchor = try read(queue) { db in
        try FullMessage.queryRequest().filter(Message.Columns.chatId == targetChat && Message.Columns.messageId == originalAnchor).fetchOne(db)
      }
      #expect(oldAnchor?.replyThread?.title == (rollback ? "Old joined title" : nil))
    } else if kind == "outsideWindowChild" {
      #expect(first.replyThread == nil)
    } else {
      #expect(first.replyThread?.title == (rollback ? "Old joined title" : "Current joined title"))
    }
    #expect(model.messages.first?.message.text == initial.message.text)
  }

  private func initialMessage(id: Int64, chat: Int64) -> Message {
    Message(messageId: id, fromId: userId, date: Date(timeIntervalSince1970: 3), text: "Context \(id)",
      peerUserId: nil, peerThreadId: chat, chatId: chat, out: true, status: .sent)
  }

  @Test("a committed File change fences the first snapshot before delayed MainActor delivery", arguments: [false, true])
  @MainActor
  func committedWriterBeforeActorDelivery(rollback: Bool) async throws {
    let (queue, appDatabase) = try database()
    let oldURL = "https://cdn.inline.chat/before-commit.jpg"
    let newURL = "https://cdn.inline.chat/after-commit.jpg"
    let source = try write(queue) { db in
      _ = try seed(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      try File(id: "held-file", fileUniqueId: "held-identity", fileType: .photo, fileName: "photo.jpg",
        uploading: false, fileSize: 1, temporaryUrl: oldURL, temporaryUrlExpiresAt: nil,
        width: 32, height: 32, localPath: nil, mimeType: "image/jpeg").insert(db)
      var source = try #require(try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId]))
      source.fileId = "held-file"
      try source.update(db)
      return source
    }
    let publisher = MessagesPublisher(database: appDatabase)
    let (readStarted, readContinuation) = AsyncStream<Void>.makeStream()
    let readGate = ProjectionReadGate(started: readContinuation)
    let (deliveryStarted, deliveryContinuation) = AsyncStream<Void>.makeStream()
    let deliveryGate = ProjectionReadGate(started: deliveryContinuation)
    var emitted: [FullMessage] = []
    let subscription = publisher.publisher.sink {
      if case let .reconcile(message?, _, _, _) = $0 { emitted.append(message) }
    }
    let targetChat = chatId, targetMessage = serverId
    let replacingId = try #require(source.globalId)
    let projection = Task { @MainActor in
      await publisher.messageReconciled(messageId: targetMessage, chatId: targetChat,
        replacingGlobalId: replacingId, peer: .thread(id: targetChat), read: {
          let snapshot = try await queue.read {
            try FullMessage.queryRequest().filter(Message.Columns.chatId == targetChat && Message.Columns.messageId == targetMessage).fetchOne($0)
          }
          await readGate.pauseFirstRead()
          return snapshot
        })
    }
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(3))
      readContinuation.finish(); deliveryContinuation.finish()
      await readGate.release(); await deliveryGate.release()
    }
    defer { watchdog.cancel(); subscription.cancel(); readContinuation.finish(); deliveryContinuation.finish() }
    var reads = readStarted.makeAsyncIterator()
    _ = await reads.next()
    enum Rollback: Error { case requested }
    do {
      try write(queue) { db in
        _ = try File.save(db, apiPhoto: ApiPhoto(fileUniqueId: "held-identity", width: 32, height: 32,
          fileSize: 1, mimeType: "image/jpeg", temporaryUrl: newURL), publisher: publisher,
          beforeAsyncNotification: { await deliveryGate.pauseFirstRead() })
        if rollback { throw Rollback.requested }
      }
    } catch Rollback.requested {}
    if !rollback {
      var deliveries = deliveryStarted.makeAsyncIterator()
      _ = await deliveries.next()
    }
    // The actual SQL writer has finished. Only its MainActor notification is
    // held; unlike the earlier writer tests, no footprint signal is awaited.
    await readGate.release()
    await projection.value
    let first = try #require(emitted.first)
    #expect(emitted.count == 1)
    #expect(first.file?.temporaryUrl == (rollback ? oldURL : newURL))
    #expect(await readGate.readCount == (rollback ? 1 : 2))
    await deliveryGate.release()
    for _ in 0..<5 { await Task.yield() }
    #expect(emitted.count == 1)
  }

  @Test("actual shared row writers fence held SQL even without a final visible message", arguments: [
    "photo", "missingPhoto", "photoCache", "photoSizePath", "video", "videoCache", "document", "documentCache", "file", "profileFile", "presence", "ackMedia", "task", "card",
  ], [false, true])
  @MainActor
  func sharedRowWriterFence(kind: String, rollback: Bool) async throws {
    let (queue, appDatabase) = try database()
    let localPhoto: Int64 = 500, serverPhoto: Int64 = 50_500
    let localVideo: Int64 = 501, serverVideo: Int64 = 50_501
    let localDocument: Int64 = 502, serverDocument: Int64 = 50_502
    let oldURL = "https://cdn.inline.chat/old-shared.jpg"
    let newURL = "https://cdn.inline.chat/new-shared.jpg"
    let source = try write(queue) { db in
      _ = try seed(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      var source = try #require(try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId]))
      if kind != "missingPhoto" {
        try Photo(id: localPhoto, photoId: serverPhoto, date: Date(timeIntervalSince1970: 1), format: .jpeg).insert(db)
        try PhotoSize(id: 510, photoId: localPhoto, width: 32, height: 32, cdnUrl: oldURL).insert(db)
      }
      switch kind {
      case "video", "videoCache":
        try Video(id: localVideo, videoId: serverVideo, date: Date(timeIntervalSince1970: 1), cdnUrl: oldURL).insert(db)
        source.videoId = serverVideo
      case "document", "documentCache":
        try Document(id: localDocument, documentId: serverDocument, date: Date(timeIntervalSince1970: 1), cdnUrl: oldURL).insert(db)
        source.documentId = serverDocument
      case "file":
        try File(id: "shared-file", fileUniqueId: "shared-identity", fileType: .photo, fileName: "photo.jpg",
          uploading: false, fileSize: 1, temporaryUrl: oldURL, temporaryUrlExpiresAt: nil,
          width: 32, height: 32, localPath: nil, mimeType: "image/jpeg").insert(db)
        source.fileId = "shared-file"
      case "missingPhoto", "card":
        try UrlPreview(id: 600, url: "https://inline.chat", siteName: nil, title: "Old card",
          description: nil, photoId: nil, authorPhotoId: kind == "missingPhoto" ? serverPhoto : nil, duration: nil).insert(db)
        try Attachment(messageId: source.globalId, externalTaskId: nil, urlPreviewId: 600, attachmentId: 601).insert(db)
      case "task":
        var task = ExternalTask(application: "linear", taskId: "shared", status: .todo,
          assignedUserId: userId, url: nil, title: "Old task", date: nil, number: "1")
        task.id = 800
        try task.insert(db)
        try Attachment(messageId: source.globalId, externalTaskId: 800, urlPreviewId: nil, attachmentId: 801).insert(db)
      case "presence", "profileFile": break
      default: source.photoId = serverPhoto
      }
      try source.update(db)
      if kind == "ackMedia" {
        let otherChat = chatId + 100
        try Chat(id: otherChat, date: Date(), type: .thread, title: "Other", spaceId: nil).insert(db)
        try Photo(id: 499, photoId: -50_499, format: .jpeg).insert(db)
        try PhotoSize(photoId: 499, localPath: "new-shared-local.jpg").insert(db)
        var pending = Message(messageId: -77, randomId: 77, fromId: userId, date: Date(), text: "Other pending",
          peerUserId: nil, peerThreadId: otherChat, chatId: otherChat, status: .sending, photoId: -50_499)
        var confirmed = Message(messageId: 2, fromId: userId, date: Date(), text: "Other confirmed",
          peerUserId: nil, peerThreadId: otherChat, chatId: otherChat, photoId: serverPhoto)
        _ = try pending.saveMessage(db)
        _ = try confirmed.saveMessage(db)
      }
      return source
    }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
      publisher: publisher, currentUserId: userId)
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let gate = ProjectionReadGate(started: continuation)
    let targetChat = chatId, targetMessage = serverId
    let replacingId = try #require(source.globalId)
    var emitted: [FullMessage] = []
    let subscription = publisher.publisher.sink { if case let .reconcile(message?, _, _, _) = $0 { emitted.append(message) } }
    defer { subscription.cancel(); model.dispose(); continuation.finish() }
    let projection = Task { @MainActor in
      defer { continuation.finish() }
      await publisher.messageReconciled(messageId: targetMessage, chatId: targetChat,
        replacingGlobalId: replacingId, peer: .thread(id: targetChat), read: {
          let snapshot = try await queue.read { db in
            try FullMessage.queryRequest().filter(Message.Columns.chatId == targetChat && Message.Columns.messageId == targetMessage).fetchOne(db)
          }
          await gate.pauseFirstRead()
          return snapshot
        })
    }
    var starts = started.makeAsyncIterator()
    _ = await starts.next()
    let mutate: (Database) throws -> Void = { db in
      switch kind {
      case "photo", "missingPhoto":
        _ = try Photo.savePhotoFromProtocol(db, photo: .with {
          $0.id = serverPhoto; $0.date = 1; $0.format = .jpeg
          $0.sizes = [.with { $0.type = "f"; $0.w = 32; $0.h = 32; $0.cdnURL = newURL }]
        }, publisher: publisher)
      case "photoCache":
        let photo = try #require(try Photo.filter(Photo.Columns.photoId == serverPhoto).fetchOne(db))
        let sizes = try PhotoSize.filter(PhotoSize.Columns.photoId == photo.id).fetchAll(db)
        try FileCache.persistDownloadedPhotoPath("new-shared-local.jpg", for: PhotoInfo(photo: photo, sizes: sizes), in: db, publisher: publisher)
      case "photoSizePath":
        try MediaHelpers.updateLocalPath(db, mediaType: .photoSize, id: 510, path: "new-shared-local.jpg", publisher: publisher)
      case "video":
        _ = try Video.updateFromProtocol(db, protoVideo: .with { $0.id = serverVideo; $0.date = 1; $0.cdnURL = newURL }, thumbnailPhotoId: nil, publisher: publisher)
      case "document":
        _ = try Document.updateFromProtocol(db, protoDocument: .with { $0.id = serverDocument; $0.date = 1; $0.cdnURL = newURL }, thumbnailPhotoId: nil, publisher: publisher)
      case "videoCache":
        let video = try #require(try Video.fetchOne(db, id: localVideo))
        try FileCache.persistDownloadedVideoPath("new-shared-local.mp4", for: VideoInfo(video: video), in: db, publisher: publisher)
      case "documentCache":
        let document = try #require(try Document.fetchOne(db, id: localDocument))
        try FileCache.persistDownloadedDocumentPath("new-shared-local.pdf", for: DocumentInfo(document: document), in: db, publisher: publisher)
      case "file":
        _ = try File.save(db, apiPhoto: ApiPhoto(fileUniqueId: "shared-identity", width: 32, height: 32,
          fileSize: 1, mimeType: "image/jpeg", temporaryUrl: newURL), publisher: publisher)
      case "profileFile":
        _ = try File.save(db, apiPhoto: ApiPhoto(fileUniqueId: "new-profile-identity", width: 32, height: 32,
          fileSize: 1, mimeType: "image/jpeg", temporaryUrl: newURL), forUserId: userId, publisher: publisher)
      case "presence":
        try InlineProtocol.UpdateUserStatus.with { $0.userID = userId; $0.status.online = .online }.apply(db, publisher: publisher)
      case "ackMedia":
        try InlineProtocol.UpdateMessageId.with { $0.randomID = 77; $0.messageID = 2 }
          .apply(db, currentUserId: userId, publisher: publisher, publish: { _, _, _, _ in })
        try Message.filter(Message.Columns.chatId == chatId + 100).updateAll(db, Message.Columns.photoId.set(to: nil))
      case "task":
        _ = try ExternalTask.save(db, externalTask: .with {
          $0.id = 800; $0.application = "linear"; $0.taskID = "shared"; $0.status = .todo
          $0.assignedUserID = userId; $0.title = "New task"
        }, publisher: publisher)
      case "card":
        _ = try UrlPreview.save(db, linkEmbed: .with { $0.id = 600; $0.url = "https://inline.chat"; $0.title = "New card" }, publisher: publisher)
      default: Issue.record("Unexpected writer")
      }
    }
    enum Rollback: Error { case requested }
    do { try write(queue) { db in try mutate(db); if rollback { throw Rollback.requested } } }
    catch Rollback.requested {}
    let key: MessageProjectionDependencies.Identity = switch kind {
    case "missingPhoto": .serverPhoto(serverPhoto)
    case "video", "videoCache": .video(localVideo)
    case "document", "documentCache": .document(localDocument)
    case "file": .file("shared-file")
    case "presence", "profileFile": .user(userId)
    case "task": .task(800)
    case "card": .urlPreview(600)
    default: .photo(localPhoto)
    }
    let dependencies = MessageProjectionDependencies(identities: [key])
    if rollback { try await Task.sleep(for: .milliseconds(20)) }
    else {
      for _ in 0..<100 where !publisher.hasActiveProjectionChanges(dependencies) { try await Task.sleep(for: .milliseconds(5)) }
    }
    #expect(publisher.hasActiveProjectionChanges(dependencies) == !rollback)
    await gate.release()
    await projection.value
    #expect(await gate.readCount == (rollback ? 1 : 2))
    #expect(emitted.count == 1)
    let first = try #require(emitted.first)
    switch kind {
    case "photo": #expect(first.photoInfo?.sizes.first?.cdnUrl == (rollback ? oldURL : newURL))
    case "missingPhoto": #expect(first.attachments.first?.authorPhotoInfo?.sizes.first?.cdnUrl == (rollback ? nil : newURL))
    case "video": #expect(first.videoInfo?.video.cdnUrl == (rollback ? oldURL : newURL))
    case "document": #expect(first.documentInfo?.document.cdnUrl == (rollback ? oldURL : newURL))
    case "videoCache": #expect(first.videoInfo?.video.localPath == (rollback ? nil : "new-shared-local.mp4"))
    case "documentCache": #expect(first.documentInfo?.document.localPath == (rollback ? nil : "new-shared-local.pdf"))
    case "file": #expect(first.file?.temporaryUrl == (rollback ? oldURL : newURL))
    case "profileFile": #expect(first.senderInfo?.profilePhoto?.first?.temporaryUrl == (rollback ? nil : newURL))
    case "presence": #expect(first.senderInfo?.user.online == (rollback ? nil : true))
    case "task": #expect(first.attachments.first?.externalTask?.title == (rollback ? "Old task" : "New task"))
    case "card": #expect(first.attachments.first?.urlPreview?.title == (rollback ? "Old card" : "New card"))
    default: #expect(first.photoInfo?.sizes.first?.localPath == (rollback ? nil : "new-shared-local.jpg"))
    }
    #expect(model.messages.first == first)
  }

  @Test("shared task deletion signals vanished identities after the actual writer commits")
  @MainActor
  func sharedTaskDeletionWhileProjectionHeld() async throws {
    let (queue, appDatabase) = try database()
    let pending = try write(queue) { try seed($0) }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
      publisher: publisher, currentUserId: userId)
    defer { model.dispose() }
    let otherChatId = chatId + 100
    try write(queue) { db in
      try Chat(id: otherChatId, date: Date(), type: .thread, title: "Other", spaceId: nil).insert(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      var task = ExternalTask(application: "linear", taskId: "shared", status: .todo,
        assignedUserId: nil, url: nil, title: "Shared task", date: nil, number: "1")
      task.id = 800
      try task.insert(db)
      let source = try #require(try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId]))
      try Attachment(messageId: source.globalId, externalTaskId: 800, urlPreviewId: nil, attachmentId: 801).insert(db)
      var other = Message(messageId: 1, fromId: userId, date: Date(), text: "Other",
        peerUserId: nil, peerThreadId: otherChatId, chatId: otherChatId)
      other = try other.saveMessage(db)
      try Attachment(messageId: other.globalId, externalTaskId: 800, urlPreviewId: nil, attachmentId: 802).insert(db)
    }
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let (published, publication) = AsyncStream<Void>.makeStream()
    let gate = ProjectionReadGate(started: continuation)
    let targetChatId = chatId, targetMessageId = serverId
    let replacingGlobalId = try #require(pending.globalId)
    var emitted: [FullMessage] = []
    let subscription = publisher.publisher.sink { update in
      if case let .update(change) = update, change.peer == .thread(id: otherChatId) {
        publication.yield(()); publication.finish()
      }
      if case let .reconcile(message?, _, _, _) = update { emitted.append(message) }
    }
    defer { subscription.cancel(); publication.finish() }
    let projection = Task { @MainActor in
      defer { continuation.finish() }
      await publisher.messageReconciled(messageId: targetMessageId, chatId: targetChatId,
        replacingGlobalId: replacingGlobalId, peer: .thread(id: targetChatId), read: {
          let snapshot = try await queue.read { db in
            try FullMessage.queryRequest().filter(Message.Columns.chatId == targetChatId && Message.Columns.messageId == targetMessageId).fetchOne(db)
          }
          await gate.pauseFirstRead()
          return snapshot
        })
    }
    var reads = started.makeAsyncIterator()
    _ = await reads.next()
    try write(queue) { db in
      try InlineProtocol.UpdateMessageAttachment.with {
        $0.chatID = otherChatId; $0.messageID = 1; $0.attachment.id = 802
      }.apply(db, publisher: publisher)
    }
    var publications = published.makeAsyncIterator()
    _ = await publications.next()
    await gate.release()
    await projection.value
    #expect(await gate.readCount == 2)
    #expect(emitted.count == 1)
    #expect(emitted.first?.attachments.isEmpty == true)
    #expect(model.messages.first?.attachments.isEmpty == true)
  }

  @Test("protocol and legacy user writers fan out only committed changed rows", arguments: [false, true])
  @MainActor
  func userWriterCommitFanout(legacy: Bool) async throws {
    let (queue, appDatabase) = try database()
    try write(queue) { _ = try seed($0) }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
      publisher: publisher, currentUserId: userId)
    let (updates, continuation) = AsyncStream<String>.makeStream()
    var emitted: [String] = []
    let subscription = publisher.publisher.sink {
      if case let .userPresentation(info) = $0 {
        emitted.append(info.user.displayName)
        continuation.yield(info.user.displayName)
      }
    }
    let watchdog = Task { try? await Task.sleep(for: .seconds(3)); continuation.finish() }
    defer { watchdog.cancel(); subscription.cancel(); model.dispose(); continuation.finish() }
    let save: (Database, String) throws -> Void = { db, name in
      if legacy {
        _ = try ApiUser(id: userId, email: nil, firstName: name, lastName: nil, date: 1, username: nil)
          .saveFull(db, publisher: publisher)
      } else {
        _ = try User.save(db, user: .with { $0.id = userId; $0.firstName = name; $0.min = true }, publisher: publisher)
      }
    }
    enum Rollback: Error { case requested }
    do { try write(queue) { db in try save(db, "Rolled back"); throw Rollback.requested } }
    catch Rollback.requested {}
    for _ in 0..<5 { await Task.yield() }
    #expect(emitted.isEmpty)
    #expect(model.messages.first?.senderInfo?.user.displayName == "Sender")
    try write(queue) { try save($0, "Committed") }
    var values = updates.makeAsyncIterator()
    #expect(await values.next() == "Committed")
    #expect(model.messages.first?.senderInfo?.user.displayName == "Committed")
    try write(queue) { try save($0, "Committed") }
    for _ in 0..<5 { await Task.yield() }
    #expect(emitted == ["Committed"])
  }

  @Test("held full snapshots protect shared rows, raw missing joins and every user relation", arguments: [
    "sharedPhoto", "sharedUser", "missingForwardUser", "missingCardAuthorPhoto",
    "reactionActor", "ackActor", "taskAssignee", "replyAuthor", "forwardPeerUser",
  ])
  @MainActor
  func delayedRichDependencies(kind: String) async throws {
    let (queue, appDatabase) = try database()
    let pending = try write(queue) { try seed($0) }
    let publisher = MessagesPublisher(database: appDatabase)
    let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
      publisher: publisher, currentUserId: userId)
    defer { model.dispose() }
    let otherChatId = chatId + 100
    let relatedUserId = kind == "sharedUser" ? userId : userId + 100
    let localPhotoId: Int64 = 500
    let serverPhotoId: Int64 = 50_500
    let oldURL = "https://cdn.inline.chat/shared.jpg?token=old"
    let latestURL = "https://cdn.inline.chat/shared.jpg?token=new"
    try write(queue) { db in
      if relatedUserId != userId, kind != "missingForwardUser" {
        try User(id: relatedUserId, email: nil, firstName: "Related").insert(db)
      }
      try Chat(id: otherChatId, date: Date(timeIntervalSince1970: 1), type: .thread,
        title: "Other chat", spaceId: nil).insert(db)
      try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
      try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
      var source = try #require(try Message.fetchOne(db, key: ["chatId": chatId, "messageId": serverId]))
      switch kind {
      case "sharedPhoto":
        try Photo(id: localPhotoId, photoId: serverPhotoId, format: .jpeg).insert(db)
        try PhotoSize(photoId: localPhotoId, cdnUrl: oldURL).insert(db)
        source.photoId = serverPhotoId
      case "missingForwardUser": source.forwardFromUserId = relatedUserId
      case "forwardPeerUser": source.forwardFromPeerUserId = relatedUserId
      case "missingCardAuthorPhoto":
        try UrlPreview(id: 600, url: "https://inline.chat", siteName: nil, title: "Card",
          description: nil, photoId: nil, authorPhotoId: serverPhotoId, duration: nil).insert(db)
        try Attachment(messageId: source.globalId, externalTaskId: nil, urlPreviewId: 600, attachmentId: 601).insert(db)
      case "reactionActor":
        try Reaction(id: 700, messageId: serverId, userId: relatedUserId,
          emoji: "👍", date: Date(), chatId: chatId).insert(db)
      case "ackActor":
        try Acknowledgement(chatId: chatId, userId: relatedUserId, maxId: serverId, revision: 1).insert(db)
      case "taskAssignee":
        var task = ExternalTask(application: "linear", taskId: "task", status: .todo,
          assignedUserId: relatedUserId, url: nil, title: "Task", date: nil, number: "1")
        task.id = 800
        try task.insert(db)
        try Attachment(messageId: source.globalId, externalTaskId: 800, urlPreviewId: nil, attachmentId: 801).insert(db)
      case "replyAuthor":
        var reply = Message(messageId: 7, fromId: relatedUserId, date: Date(), text: "Parent quote",
          peerUserId: nil, peerThreadId: chatId, chatId: chatId)
        _ = try reply.saveMessage(db)
        source.repliedToMessageId = 7
      default: break
      }
      try source.update(db)
      var other = Message(messageId: 1, fromId: userId, date: Date(), text: "Other",
        peerUserId: nil, peerThreadId: otherChatId, chatId: otherChatId)
      _ = try other.saveMessage(db)
    }
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let gate = ProjectionReadGate(started: continuation)
    let targetChatId = chatId, targetMessageId = serverId
    var emitted: [FullMessage] = []
    let subscription = publisher.publisher.sink { update in
      if case let .reconcile(message?, _, _, _) = update { emitted.append(message) }
    }
    defer { subscription.cancel() }
    let replacingGlobalId = try #require(pending.globalId)
    let projection = Task { @MainActor in
      defer { continuation.finish() }
      await publisher.messageReconciled(messageId: targetMessageId, chatId: targetChatId,
        replacingGlobalId: replacingGlobalId, peer: .thread(id: targetChatId), read: {
          let snapshot = try await queue.read { db in
            try FullMessage.queryRequest().filter(Message.Columns.chatId == targetChatId && Message.Columns.messageId == targetMessageId).fetchOne(db)
          }
          await gate.pauseFirstRead()
          return snapshot
        })
    }
    var reads = started.makeAsyncIterator()
    _ = await reads.next()
    let changed = try write(queue) { db in
      if kind == "sharedPhoto" {
        try PhotoSize.filter(PhotoSize.Columns.photoId == localPhotoId).updateAll(db, [PhotoSize.Columns.cdnUrl.set(to: latestURL)])
      } else if kind == "missingCardAuthorPhoto" {
        try Photo(id: localPhotoId, photoId: serverPhotoId, format: .jpeg).insert(db)
        try PhotoSize(photoId: localPhotoId, cdnUrl: latestURL).insert(db)
      } else {
        var related = try User.fetchOne(db, id: relatedUserId) ?? User(id: relatedUserId, email: nil, firstName: "Related")
        related.profileCdnUrl = latestURL
        try related.save(db)
      }
      var other = try #require(try Message.fetchOne(db, key: ["chatId": otherChatId, "messageId": 1]))
      if kind == "sharedPhoto" || kind == "missingCardAuthorPhoto" { other.photoId = serverPhotoId }
      else { other.fromId = relatedUserId }
      try other.update(db)
      return other
    }
    // This publication belongs to a different chat. It carries a shared row
    // that the held actual snapshot reads, including absent optional joins.
    publisher.messageUpdatedSync(message: changed, peer: .thread(id: otherChatId), animated: false)
    await gate.release()
    await projection.value
    #expect(await gate.readCount == 2)
    let first = try #require(emitted.first)
    #expect(emitted.count == 1)
    let observedURL: String?
    switch kind {
    case "sharedPhoto": observedURL = first.photoInfo?.sizes.first?.cdnUrl
    case "missingCardAuthorPhoto": observedURL = first.attachments.first?.authorPhotoInfo?.sizes.first?.cdnUrl
    case "missingForwardUser": observedURL = first.forwardFromUserInfo?.user.profileCdnUrl
    case "forwardPeerUser": observedURL = first.forwardFromPeerUserInfo?.user.profileCdnUrl
    case "reactionActor": observedURL = first.reactions.first?.userInfo?.user.profileCdnUrl
    case "ackActor": observedURL = first.acknowledgements?.first?.userInfo?.user.profileCdnUrl
    case "taskAssignee": observedURL = first.attachments.first?.userInfo?.user.profileCdnUrl
    case "replyAuthor": observedURL = first.repliedToMessage?.senderInfo?.user.profileCdnUrl
    default: observedURL = first.senderInfo?.user.profileCdnUrl
    }
    #expect(observedURL == latestURL)
    #expect(model.messages.first?.message.messageId == serverId)
  }

  @Test("reversed async completions cannot cause a retry cycle or stale user publication")
  @MainActor
  func reversedUserReadCompletions() async throws {
    let (queue, appDatabase) = try database()
    try write(queue) { _ = try seed($0) }
    let publisher = MessagesPublisher(database: appDatabase)
    let senderId = userId
    let (oldStarted, oldContinuation) = AsyncStream<Void>.makeStream()
    let (newStarted, newContinuation) = AsyncStream<Void>.makeStream()
    let oldGate = ProjectionReadGate(started: oldContinuation)
    let newGate = ProjectionReadGate(started: newContinuation)
    var names: [String] = []
    let subscription = publisher.publisher.sink { if case let .userPresentation(info) = $0 { names.append(info.user.displayName) } }
    defer { subscription.cancel() }
    let older = Task { @MainActor in
      defer { oldContinuation.finish() }
      await publisher.userPresentationUpdated(userId: senderId, read: {
        let snapshot = try await queue.read { try User.userInfoQuery().filter(User.Columns.id == senderId).fetchOne($0) }
        await oldGate.pauseFirstRead()
        return snapshot
      })
    }
    var oldReads = oldStarted.makeAsyncIterator()
    _ = await oldReads.next()
    try write(queue) { db in
      var user = try #require(try User.fetchOne(db, id: userId))
      user.firstName = "Latest"
      try user.update(db)
    }
    let newer = Task { @MainActor in
      defer { newContinuation.finish() }
      await publisher.userPresentationUpdated(userId: senderId, read: {
        let snapshot = try await queue.read { try User.userInfoQuery().filter(User.Columns.id == senderId).fetchOne($0) }
        await newGate.pauseFirstRead()
        return snapshot
      })
    }
    var newReads = newStarted.makeAsyncIterator()
    _ = await newReads.next()
    await oldGate.release()
    await older.value
    await newGate.release()
    await newer.value
    #expect(await oldGate.readCount == 2)
    // The older admission refetched a fresh snapshot and published it first;
    // the newer admission's held SQL result must respect that publication.
    #expect(await newGate.readCount == 2)
    #expect(names == ["Latest", "Latest"])
  }

  @Test("unrelated continuing commits cannot postpone a current projection")
  @MainActor
  func projectionProgressUnderContinuingUnrelatedCommits() async throws {
    // Deliberately sequential: no cross-case MainActor load or shared database.
    for reconcile in [false, true] {
      for overlapEachRead in [false, true] {
        let (queue, appDatabase) = try database()
        let noiseChatId = chatId + 100
        let noiseUserId = userId + 100
        let latestURL = "https://cdn.inline.chat/current.jpg?token=new"
        let pending = try write(queue) { db in
          let pending = try seed(db)
          var sender = try #require(try User.fetchOne(db, id: userId))
          sender.profileFileUniqueId = "same-photo"
          sender.profileCdnUrl = "https://cdn.inline.chat/current.jpg?token=old"
          try sender.update(db)
          try User(id: noiseUserId, email: nil, firstName: "Unrelated 0").insert(db)
          try Chat(id: noiseChatId, date: Date(timeIntervalSince1970: 1), type: .thread,
                   title: "Unrelated load", spaceId: nil).insert(db)
          var unrelated = Message(messageId: 1, fromId: noiseUserId,
            date: Date(timeIntervalSince1970: 11), text: "Unrelated 0",
            peerUserId: nil, peerThreadId: noiseChatId, chatId: noiseChatId,
            out: false, status: .sent)
          _ = try unrelated.saveMessage(db)
          return pending
        }
        let publisher = MessagesPublisher(database: appDatabase)
        let model = MessagesProgressiveViewModel(peer: .thread(id: chatId), database: appDatabase,
                                                publisher: publisher, currentUserId: userId)
        defer { model.dispose() }
        try write(queue) { db in
          var sender = try #require(try User.fetchOne(db, id: userId))
          sender.profileCdnUrl = latestURL
          try sender.update(db)
          if reconcile {
            try newMessage.apply(db, publishChanges: false, suppressNotifications: true)
            try confirmation.apply(db, currentUserId: userId, publish: { _, _, _, _ in })
          }
        }

        let (started, firstReadStarted) = AsyncStream<Void>.makeStream()
        let gate = ContinuingProjectionLoadGate(firstReadStarted: firstReadStarted,
                                                overlapEachRead: overlapEachRead)
        let sourceChatId = chatId, sourceMessageId = serverId, sourceUserId = userId
        let replacingGlobalId = try #require(pending.globalId)
        let clock = ContinuousClock()
        var completedAt: ContinuousClock.Instant?
        var watchdogFired = false
        var activeNoise: Task<Void, any Error>?
        let watchdog = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(5)) }
          catch { return }
          watchdogFired = true
          activeNoise?.cancel()
          // Failure-only cleanup; it cannot count as progress under load.
          publisher.closeAdmissionForTermination()
          await gate.stopNoiseAndRelease()
        }
        defer { watchdog.cancel() }
        let projection = Task { @MainActor in
          if reconcile {
            await publisher.messageReconciled(messageId: sourceMessageId, chatId: sourceChatId,
              replacingGlobalId: replacingGlobalId, peer: .thread(id: sourceChatId), read: {
                let snapshot = try await queue.read { db in
                  try FullMessage.queryRequest()
                    .filter(Message.Columns.chatId == sourceChatId && Message.Columns.messageId == sourceMessageId)
                    .fetchOne(db)
                }
                // GRDB has finished and its transaction/lock has been released.
                await gate.snapshotFinished()
                return snapshot
              })
          } else {
            await publisher.userPresentationUpdated(userId: sourceUserId, read: {
              let snapshot = try await queue.read { db in
                try User.userInfoQuery().filter(User.Columns.id == sourceUserId).fetchOne(db)
              }
              await gate.snapshotFinished()
              return snapshot
            })
          }
          completedAt = clock.now
        }
        var firstReads = started.makeAsyncIterator()
        guard await firstReads.next() != nil else {
          await projection.value
          Issue.record("The initial real SQL snapshot did not reach the test gate before the watchdog")
          return
        }

        let noise = Task { @MainActor in
          var iteration = 0
          while !Task.isCancelled {
            iteration += 1
            let sequence = iteration
            let changed = try await queue.write { db in
              var sender = try #require(try User.fetchOne(db, id: noiseUserId))
              sender.firstName = "Unrelated \(sequence)"
              try sender.update(db)
              var message = try #require(try Message.fetchOne(db, key: ["chatId": noiseChatId, "messageId": 1]))
              message.text = "Unrelated \(sequence)"
              message.rev = Int64(sequence)
              try message.update(db)
              return message
            }
            // Actual committed records through the production publication path.
            publisher.messageUpdatedSync(message: changed, peer: .thread(id: noiseChatId), animated: false)
            await publisher.userPresentationUpdated(userId: noiseUserId)
            publisher.messagesReload(peer: .thread(id: noiseChatId), animated: false)
            await gate.noisePublished()
            try await Task.sleep(for: .milliseconds(1))
          }
        }
        activeNoise = noise
        // Polling is bounded and only arms the controlled first-read release.
        for _ in 0..<100 {
          if await gate.publicationCount >= 2 { break }
          try await Task.sleep(for: .milliseconds(5))
        }
        let initialNoiseCount = await gate.publicationCount
        let releasedAt = clock.now
        await gate.releaseFirstRead()
        if initialNoiseCount >= 2 {
          // Continue noise independently even if the target has already finished.
          try await Task.sleep(for: .milliseconds(500))
        }
        let completedDuringLoad = completedAt != nil
        let readsDuringLoad = await gate.readCount
        let publicationsDuringLoad = await gate.publicationCount
        noise.cancel()
        await gate.stopNoiseAndRelease()
        var noiseFailure: (any Error)?
        do { try await noise.value }
        catch is CancellationError {}
        catch { noiseFailure = error }
        // Quiet completion is measured separately; it is not accepted as load progress.
        await projection.value
        let totalDuration = releasedAt.duration(to: clock.now)
        let totalMilliseconds = Double(totalDuration.components.attoseconds) / 1e15
          + Double(totalDuration.components.seconds) * 1_000
        let completionMilliseconds = completedAt.map {
          Double(releasedAt.duration(to: $0).components.attoseconds) / 1e15
            + Double(releasedAt.duration(to: $0).components.seconds) * 1_000
        } ?? -1
        print("projection_load target=\(reconcile ? "ack" : "user") overlap=\(overlapEachRead) completed_during_load=\(completedDuringLoad) reads_during_load=\(readsDuringLoad) reads_total=\(await gate.readCount) unrelated_publications=\(publicationsDuringLoad) completion_ms=\(completionMilliseconds) total_ms=\(totalMilliseconds)")
        if let noiseFailure { throw noiseFailure }
        #expect(!watchdogFired)
        #expect(initialNoiseCount >= 2)
        // Real commits run at the machine's actual speed. Qualify sustained
        // producer progress after release, rather than an arbitrary SQL rate.
        #expect(publicationsDuringLoad >= initialNoiseCount + 5)
        if overlapEachRead {
          // No retry may be caused by these disjoint known users/messages.
          #expect(completedDuringLoad)
          #expect(readsDuringLoad <= 2)
        }
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.message.text == (reconcile ? "canonical text" : "pending text"))
        #expect(model.messages.first?.senderInfo?.user.profileCdnUrl == latestURL)
        if reconcile { #expect(model.messages.first?.message.messageId == sourceMessageId) }
      }
    }
  }
}

// Only test scheduling/metrics. Never holds a GRDB lock, mutates a publisher
// generation, or supplies a simulated projection. Noise runs independently.
private actor ContinuingProjectionLoadGate {
  let firstReadStarted: AsyncStream<Void>.Continuation
  let overlapEachRead: Bool
  private var firstReadRelease: CheckedContinuation<Void, Never>?
  private var noiseWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var noiseStopped = false
  private(set) var readCount = 0
  private(set) var publicationCount = 0

  init(firstReadStarted: AsyncStream<Void>.Continuation, overlapEachRead: Bool) {
    self.firstReadStarted = firstReadStarted
    self.overlapEachRead = overlapEachRead
  }

  func snapshotFinished() async {
    readCount += 1
    guard !noiseStopped else {
      firstReadStarted.finish()
      return
    }
    if readCount == 1 {
      await withCheckedContinuation { continuation in
        firstReadRelease = continuation
        firstReadStarted.yield(())
        firstReadStarted.finish()
      }
    } else if overlapEachRead, !noiseStopped {
      let capturedOrdinal = publicationCount
      await withCheckedContinuation { continuation in
        noiseWaiters.append((capturedOrdinal, continuation))
      }
    }
  }

  func noisePublished() {
    publicationCount += 1
    let ready = noiseWaiters.filter { $0.0 < publicationCount }
    noiseWaiters.removeAll { $0.0 < publicationCount }
    for (_, continuation) in ready { continuation.resume() }
  }

  func releaseFirstRead() {
    firstReadRelease?.resume()
    firstReadRelease = nil
  }

  func stopNoiseAndRelease() {
    noiseStopped = true
    firstReadStarted.finish()
    releaseFirstRead()
    let waiters = noiseWaiters
    noiseWaiters.removeAll()
    for (_, continuation) in waiters { continuation.resume() }
  }
}

private actor ProjectionReadGate {
  let started: AsyncStream<Void>.Continuation
  var releaseContinuation: CheckedContinuation<Void, Never>?
  private(set) var readCount = 0
  init(started: AsyncStream<Void>.Continuation) { self.started = started }
  func pauseFirstRead() async {
    readCount += 1
    guard readCount == 1 else { return }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
      started.yield(())
      started.finish()
    }
  }
  func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}
