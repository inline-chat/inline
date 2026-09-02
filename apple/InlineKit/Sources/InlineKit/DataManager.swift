import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

enum DataManagerError: Error {
  case networkError
  case apiError(description: String, code: Int)
  case localSaveError
  case notAuthorized
}

// ?? should we use main actor here?

/// Query or mutate data on the server and update local database
@MainActor
public class DataManager: ObservableObject {
  private var database: AppDatabase
  private let auth: AuthHandle
  private var log = Log.scoped("DataManager")

  public init(database: AppDatabase, auth: AuthHandle = Auth.shared.handle) {
    self.database = database
    self.auth = auth
  }

  public static let shared = DataManager(database: AppDatabase.shared, auth: Auth.shared.handle)

  private func beginAccountMutation() throws -> AuthAccountMutationToken {
    try auth.beginAccountMutation()
  }

  private func writeAccountProjection<Result: Sendable>(
    token: AuthAccountMutationToken,
    _ updates: @escaping @Sendable (Database) throws -> Result
  ) async throws -> Result {
    let auth = self.auth
    return try await database.dbWriter.write { db in
      try auth.validateAccountMutation(token)
      return try updates(db)
    }
  }

  public func fetchMe() async throws -> User {
    log.trace("fetchMe")
    let mutationToken = try beginAccountMutation()
    do {
      let result = try await InlineRPCClient.shared.getMe()

      let user = try await writeAccountProjection(token: mutationToken) { db in
        try User.save(db, user: result.user)
      }

      return user
    } catch {
      log.error("Error fetching user", error: error)
      throw error
    }
  }

  public func createSpace(name: String) async throws -> Int64? {
    log.trace("createSpace")
    let mutationToken = try beginAccountMutation()
    do {
      let result = try await InlineRPCClient.shared.createSpace(name: name)
      let space = Space(from: result.space)
      let log = self.log
      try await writeAccountProjection(token: mutationToken) { db in
        do {
          try space.save(db)
        } catch {
          log.error("Failed to save space", error: error)
        }
        do {
          try Member(from: result.member).save(db)
        } catch {
          log.error("Failed to save member", error: error)
        }
        do {
          _ = try Chat(from: result.chat).saveFull(db)
          try Dialog(from: result.dialog).save(db, onConflict: .replace)
        } catch {
          log.error("Failed to save chat", error: error)
        }
      }
      return space.id
    } catch {
      log.error("Failed to create space", error: error)
      throw error
    }
  }

  public func createThread(spaceId: Int64, title: String, emoji: String? = nil) async throws -> Int64? {
    log.trace("createThread")
    let mutationToken = try beginAccountMutation()
    do {
      let result = try await InlineRPCClient.shared.createThread(title: title, spaceID: spaceId, emoji: emoji)
      // Create the chat
      let chat = Chat(from: result.chat)
      try await writeAccountProjection(token: mutationToken) { db in
        _ = try chat.saveFull(db)
      }
      return chat.id

    } catch {
      log.error("Failed to create thread", error: error)
      throw error
    }
  }

  public func createPrivateChat(userId: Int64) async throws -> Peer {
    log.trace("createPrivateChat")
    let mutationToken = try beginAccountMutation()
    do {
      let result = try await ApiClient.shared.createPrivateChat(userId: userId)

      try await writeAccountProjection(token: mutationToken) { db in
        try result.user.saveFull(db)

        var chat = Chat(from: result.chat)
        try chat.saveWithValidLastMsg(db)

        try result.dialog.saveFull(db)
      }

      return Peer.user(id: result.user.id)
    } catch {
      log.error("Failed to create private chat", error: error)
      throw error
    }
  }

  public func createPrivateChatWithOptimistic(user: ApiUser) async throws {
    log.trace("createPrivateChat with optimistic")
    let mutationToken = try beginAccountMutation()

    // Optimistic
    try await writeAccountProjection(token: mutationToken) { db in
      try user.saveFull(db)
      let dialog = Dialog(optimisticForUserId: user.id)
      try dialog.save(db, onConflict: .ignore)
    }
    log.trace("saved optimistic")

    let userId = user.id

    // Do in background
    // FIXME: this should be in background but UI will fail
    // Task { @MainActor in
    do {
      // Remote call
      let result = try await ApiClient.shared.createPrivateChat(userId: userId)
      try await writeAccountProjection(token: mutationToken) { db in
        try result.user.saveFull(db)

        var chat = Chat(from: result.chat)
        try chat.saveWithValidLastMsg(db)

        try result.dialog.saveFull(db)
      }
      log.info("Created private chat with \(user.anyName) with chatID: \(result.chat.id)")
    } catch {
      Log.shared.error("Failed to create private chat", error: error)
      throw error
    }
    /// }
  }

  /// Returns the user-space catalog already owned by realtime sync.
  ///
  /// Screens observe this same table, so this compatibility method must not
  /// start an independent account snapshot or fan out one roster request per
  /// space.
  @discardableResult
  public func getSpaces() async throws -> [Space] {
    log.trace("getSpaces")
    let mutationToken = try beginAccountMutation()
    let auth = self.auth
    let spaces = try await database.reader.read { db in
      try auth.validateAccountMutation(mutationToken)
      return try Space.catalogActive().fetchAll(db)
    }
    try auth.validateAccountMutation(mutationToken)
    return spaces
  }

  /// Get one user
  public func getUser(id: Int64) async throws {
    log.trace("getUser")
    let mutationToken = try beginAccountMutation()
    do {
      let result = try await InlineRPCClient.shared.getChat(peerID: .user(id: id))
      guard result.hasUser else { throw InlineRPCClientError.unexpectedResponse }

      let _ = try await writeAccountProjection(token: mutationToken) { db in
        try User.save(db, user: result.user)
      }
    } catch {
      throw error
    }
  }

  public func deleteSpace(spaceId: Int64) async throws {
    log.trace("deleteSpace")
    let mutationToken = try beginAccountMutation()
    do {
      try await writeAccountProjection(token: mutationToken) { db in
        try Space.deleteOne(db, id: spaceId)

        try Member
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)

        try Dialog.filter(Column("spaceId") == spaceId)
          .deleteAll(db)

        try Chat
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)
      }

      try await InlineRPCClient.shared.deleteSpace(spaceID: spaceId)

    } catch {
      log.error("Failed to delete space", error: error)
      throw error
    }
  }

  public func leaveSpace(spaceId: Int64) async throws {
    log.trace("leaveSpace")
    let mutationToken = try beginAccountMutation()
    do {
      try await writeAccountProjection(token: mutationToken) { db in
        try Space.deleteOne(db, id: spaceId)

        try Member
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)

        try Chat
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)
      }

      try await InlineRPCClient.shared.leaveSpace(spaceID: spaceId)
    } catch {
      log.error("Failed to leave space", error: error)
      throw error
    }
  }

  @discardableResult
  public func getPrivateChats() async throws -> [Chat] {
    log.trace("getPrivateChats")
    let mutationToken = try beginAccountMutation()
    let auth = self.auth
    let chats = try await database.reader.read { db in
      try auth.validateAccountMutation(mutationToken)
      return try Chat
        .filter(Chat.Columns.type == ChatType.privateChat.rawValue)
        .fetchAll(db)
    }
    try auth.validateAccountMutation(mutationToken)
    return chats
  }

  /// Returns the local dialog projection for one space. Realtime sync is the
  /// sole network owner of this catalog.
  @discardableResult
  public func getDialogs(spaceId: Int64) async throws -> [Dialog] {
    log.trace("get local dialogs for space \(spaceId)")
    let mutationToken = try beginAccountMutation()
    let auth = self.auth
    let dialogs = try await database.reader.read { db in
      try auth.validateAccountMutation(mutationToken)
      return try Dialog
        .filter(Dialog.Columns.spaceId == spaceId)
        .fetchAll(db)
    }
    try auth.validateAccountMutation(mutationToken)
    return dialogs
  }

  public func getChatHistory(
    peerUserId: Int64?,
    peerThreadId: Int64?,
    peerId: Peer?
  ) async throws {
    let mutationToken = try beginAccountMutation()
    let finalPeerUserId: Int64?
    let finalPeerThreadId: Int64?
    var peerId_: Peer

    if let peerId {
      switch peerId {
        case let .user(id):
          finalPeerUserId = id
          finalPeerThreadId = nil
        case let .thread(id):
          finalPeerUserId = nil
          finalPeerThreadId = id
      }

      peerId_ = peerId
    } else {
      finalPeerUserId = peerUserId
      finalPeerThreadId = peerThreadId

      if let peerUserId {
        peerId_ = .user(id: peerUserId)
      } else if let peerThreadId {
        peerId_ = .thread(id: peerThreadId)
      } else {
        Log.shared.error("getChatHistory: peerId is nil")
        return
      }
    }

    log.trace(
      "getChatHistory with peerUserId: \(String(describing: finalPeerUserId)), peerThreadId: \(String(describing: finalPeerThreadId))"
    )

    let historyResult = try await InlineRPCClient.shared.getChatHistory(peerID: peerId_)
    let transaction = GetChatHistoryTransaction(
      peer: peerId_,
      mode: .historyModeLatest,
      limit: 100
    )

    try await writeAccountProjection(token: mutationToken) { db in
      try GetChatHistoryTransaction.apply(historyResult, context: transaction.context, db: db)
    }

    // Publish
    // Reload messages
    Task { @MainActor in
      MessagesPublisher.shared.messagesReload(peer: peerId_, animated: true)
    }
  }

  public func addReaction(messageId: Int64, chatId: Int64, emoji: String) async throws {
    let peerID = try await database.reader.read { db -> Peer in
      guard let chat = try Chat.fetchOne(db, key: chatId) else {
        throw InlineRPCClientError.unexpectedResponse
      }
      return chat.peerId.toPeer()
    }
    try await InlineRPCClient.shared.addReaction(peerID: peerID, messageID: messageId, emoji: emoji)
  }

  @available(*, unavailable, message: "Presence is owned by the realtime connection lifecycle")
  public func updateStatus(online: Bool) async throws {
    log.trace("updateStatus: \(online)")
  }

  public func updateDialog(
    peerId: Peer,
    pinned: Bool? = nil,
    draft: MessageDraft? = nil,
    archived: Bool? = nil,
    spaceId: Int64? = nil,
    order: String? = nil,
    pinnedOrder: String? = nil,
    deleteEmptyThreadIfArchiving: Bool = true
  ) async throws {
    let mutationToken = try beginAccountMutation()
    if archived == true, deleteEmptyThreadIfArchiving, case .thread = peerId {
      if try await deleteThreadIfUntitledAndEmpty(peerId: peerId, mutationToken: mutationToken) {
        return
      }
    }

    let originalDialog = try await database.reader.read { db in
      try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId))
    }

    let requestOrder = try await writeAccountProjection(token: mutationToken) { db -> (order: String?, pinnedOrder: String?) in
      var orderForRequest: String?
      var pinnedOrderForRequest: String?
      var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId))

      if dialog == nil {
        switch peerId {
          case let .user(id):
            var optimistic = Dialog(optimisticForUserId: id)
            if let spaceId {
              optimistic.spaceId = spaceId
            }
            dialog = optimistic
          case .thread:
            break
        }
      }

      if let pinned {
        dialog?.pinned = pinned
        if let order {
          dialog?.order = order
          orderForRequest = order
        }
        if let pinnedOrder {
          dialog?.pinnedOrder = pinnedOrder
          pinnedOrderForRequest = pinnedOrder
        }
        if pinned {
          if dialog?.order == nil {
            let order = try Dialog.nextSidebarOrder(db)
            dialog?.order = order
            orderForRequest = order
          }
          if dialog?.pinnedOrder == nil {
            let pinnedOrder = try Dialog.nextPinnedOrder(db)
            dialog?.pinnedOrder = pinnedOrder
            pinnedOrderForRequest = pinnedOrder
          }
          dialog?.open = true
          dialog?.chatListHidden = nil
        } else if dialog?.open == true, dialog?.order == nil {
          let order = try Dialog.nextSidebarOrder(db)
          dialog?.order = order
          orderForRequest = order
        }
      } else {
        if let order {
          dialog?.order = order
          orderForRequest = order
        }
        if let pinnedOrder {
          dialog?.pinnedOrder = pinnedOrder
          pinnedOrderForRequest = pinnedOrder
        }
      }
      if let draft {
        // Convert string draft to DraftMessage for storage
        let draftMessage = InlineProtocol.DraftMessage.with {
          $0.text = draft.text
          if let entities = draft.entities {
            $0.entities = entities
          }
        }
        dialog?.draftMessage = draftMessage
      }
      if let archived {
        dialog?.archived = archived
        if archived == false {
          dialog?.chatListHidden = nil
        }
      }
      if dialog?.spaceId == nil, let spaceId {
        dialog?.spaceId = spaceId
      }

      try dialog?.save(db, onConflict: .replace)
      return (orderForRequest, pinnedOrderForRequest)
    }

    do {
      if let archived {
        try await InlineRPCClient.shared.updateDialogArchived(peerID: peerId, archived: archived)
      }
      if pinned != nil || requestOrder.order != nil || requestOrder.pinnedOrder != nil {
        let response = try await InlineRPCClient.shared.updateDialogOrder(
          peerID: peerId,
          pinned: pinned,
          order: requestOrder.order,
          pinnedOrder: requestOrder.pinnedOrder
        )
        try await writeAccountProjection(token: mutationToken) { db in
          try Dialog(from: response.dialog).save(db, onConflict: .replace)
        }
      }
    } catch {
      await rollbackDialogUpdate(
        original: originalDialog,
        peerId: peerId,
        mutationToken: mutationToken,
        fields: DialogUpdateRollbackFields(
          pinned: pinned != nil,
          draft: draft != nil,
          archived: archived != nil,
          spaceID: spaceId != nil,
          order: order != nil,
          pinnedOrder: pinnedOrder != nil
        )
      )
      throw error
    }
  }

  private struct DialogUpdateRollbackFields {
    let pinned: Bool
    let draft: Bool
    let archived: Bool
    let spaceID: Bool
    let order: Bool
    let pinnedOrder: Bool
  }

  private func rollbackDialogUpdate(
    original: Dialog?,
    peerId: Peer,
    mutationToken: AuthAccountMutationToken,
    fields: DialogUpdateRollbackFields
  ) async {
    do {
      try await writeAccountProjection(token: mutationToken) { db in
        guard let original else {
          try Dialog.deleteOne(db, key: Dialog.getDialogId(peerId: peerId))
          return
        }
        guard var current = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId)) else {
          return
        }

        if fields.pinned {
          current.pinned = original.pinned
          current.open = original.open
          current.openedDate = original.openedDate
          current.order = original.order
          current.pinnedOrder = original.pinnedOrder
          current.chatListHidden = original.chatListHidden
        }
        if fields.draft {
          current.draftMessage = original.draftMessage
        }
        if fields.archived {
          current.archived = original.archived
          current.chatListHidden = original.chatListHidden
        }
        if fields.order {
          current.order = original.order
        }
        if fields.pinnedOrder {
          current.pinnedOrder = original.pinnedOrder
        }
        if fields.spaceID, original.spaceId == nil {
          current.spaceId = nil
        }

        try current.save(db, onConflict: .replace)
      }
    } catch {
      log.error("Failed to roll back dialog update", error: error)
    }
  }

  /// Deletes a thread only when it is untitled and has no messages.
  /// - Parameter canDelete: Optional synchronous final check after the database read.
  ///   A caller can cancel cleanup if the thread reopened while eligibility was
  ///   being read. Existing callers omit it. This does not indicate deletion success.
  /// - Returns: `true` when deletion was performed; otherwise `false`.
  @discardableResult
  public func deleteThreadIfUntitledAndEmpty(
    peerId: Peer,
    mutationToken suppliedMutationToken: AuthAccountMutationToken? = nil,
    canDelete: (@MainActor () -> Bool)? = nil
  ) async throws -> Bool {
    guard case let .thread(threadId) = peerId else { return false }
    let mutationToken = try suppliedMutationToken ?? beginAccountMutation()

    let shouldDelete = try await database.reader.read { db in
      guard let chat = try Chat.fetchOne(db, id: threadId), chat.type == .thread else { return false }
      let trimmedTitle = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let isUntitled = chat.isUntitled == true || trimmedTitle == nil || trimmedTitle?.isEmpty == true
      let hasNoMessages = chat.lastMsgId == nil || chat.lastMsgId == 0
      return isUntitled && hasNoMessages
    }

    guard shouldDelete else { return false }
    guard canDelete?() != false else { return false }

    do {
      _ = try await Api.realtime.send(.deleteChat(peerId: peerId))
      try await writeAccountProjection(token: mutationToken) { db in
        do {
          try Message.filter(Column("chatId") == threadId).deleteAll(db)
        } catch {
          Log.shared.error("Failed to delete chat messages", error: error)
        }

        do {
          try Dialog.filter(Column("peerThreadId") == threadId).deleteAll(db)
        } catch {
          Log.shared.error("Failed to delete dialog", error: error)
        }

        do {
          try Chat.filter(Column("id") == threadId).deleteAll(db)
        } catch {
          Log.shared.error("Failed to delete chat", error: error)
        }
      }

      Task.detached {
        NotificationCenter.default.post(
          name: Notification.Name("chatDeletedNotification"),
          object: nil,
          userInfo: ["chatId": threadId]
        )
      }

      return true
    } catch let error as RealtimeAPIError {
      switch error {
        case let .rpcError(errorCode, _, code)
        where errorCode == .unauthenticated || code == 403:
          log.warning("Delete chat not permitted")
          return false
        default:
          throw error
      }
    }
  }

  public func getSpace(spaceId: Int64) async throws {
    let mutationToken = try beginAccountMutation()
    let result = try await InlineRPCClient.shared.getSpace(spaceID: spaceId)
    let imported = try await writeAccountProjection(token: mutationToken) { db in
      try Self.applyTargetedSpaceSnapshot(
        result,
        expectedSpaceID: spaceId,
        authenticatedUserID: mutationToken.userID,
        in: db
      )
    }
    try auth.validateAccountMutation(mutationToken)
    guard let target = imported.catchUpTarget else { return }
    _ = try await Api.realtime.installSnapshotOutcome(
      seededStates: [:],
      catchUpTargets: [.space(id: spaceId): target],
      expectedAccount: mutationToken
    )
  }

  struct TargetedSpaceSnapshotImport: Sendable, Equatable {
    var applied: Bool
    var catchUpTarget: Int64?
  }

  @discardableResult
  nonisolated static func applyTargetedSpaceSnapshot(
    _ result: InlineProtocol.GetSpaceResult,
    expectedSpaceID spaceId: Int64,
    authenticatedUserID: Int64,
    in db: Database
  ) throws -> TargetedSpaceSnapshotImport {
    guard result.hasSpace,
          result.hasMembership,
          result.space.id == spaceId,
          result.space.id > 0,
          result.membership.id > 0,
          result.membership.spaceID == spaceId,
          result.membership.userID == authenticatedUserID
    else {
      throw InlineRPCClientError.unexpectedResponse
    }

    let bucketKey = BucketKey.space(id: spaceId)
    let durableCursorSequence = try DbBucketState
      .filter(
        DbBucketState.Columns.bucketType == bucketKey.getBucket()
          && DbBucketState.Columns.entityId == bucketKey.getEntityId()
      )
      .fetchOne(db)?
      .seq
    let existing = try Space.fetchOne(db, key: spaceId)
    let durableSequence = durableCursorSequence ?? 0
    let existingSequence = existing?.seq.flatMap { $0 >= 0 ? Int64($0) : nil }

    // A targeted metadata refresh does not own the bucket cursor. If live
    // replay has already advanced beyond this response, keep the newer
    // projection and let the normal bucket owner continue.
    let catchUpTarget: Int64?
    let shouldSave: Bool
    if result.space.hasSeq {
      let snapshotSequence = Int64(result.space.seq)
      guard snapshotSequence >= 0 else { throw InlineRPCClientError.unexpectedResponse }
      let knownSequence = max(existingSequence ?? 0, snapshotSequence)
      catchUpTarget = knownSequence > durableSequence ? knownSequence : nil
      shouldSave = snapshotSequence >= durableSequence
        && snapshotSequence >= (existingSequence ?? 0)
    } else {
      // An unsequenced response is only safe to import into a genuinely
      // pristine projection. Every unsequenced response still gets one
      // targeted authoritative-latest request, never an account-wide sweep.
      catchUpTarget = 0
      shouldSave = existing == nil && durableCursorSequence == nil
    }

    guard shouldSave else {
      if catchUpTarget != nil, var existing, existing.memberRosterComplete {
        existing.memberRosterComplete = false
        try existing.save(db)
      }
      return TargetedSpaceSnapshotImport(applied: false, catchUpTarget: catchUpTarget)
    }

    var space = Space(from: result.space)
    space.memberRosterComplete = catchUpTarget == nil
      ? existing?.memberRosterComplete ?? false
      : false
    try space.save(db)
    try Member(from: result.membership).save(db)
    return TargetedSpaceSnapshotImport(applied: true, catchUpTarget: catchUpTarget)
  }

  public func addMember(spaceId: Int64, userId: Int64) async throws {
    let mutationToken = try beginAccountMutation()
    let result = try await InlineRPCClient.shared.inviteToSpace(spaceID: spaceId, userID: userId)
    try await writeAccountProjection(token: mutationToken) { db in
      let member = Member(from: result.member)
      try member.save(db, onConflict: .replace)
      if result.hasUser { _ = try User.save(db, user: result.user) }
    }
  }

  public func deleteMessage(
    messageId: Int64, chatId: Int64, peerId: Peer
  ) async throws {
    let mutationToken = try beginAccountMutation()
    try await InlineRPCClient.shared.deleteMessage(peerID: peerId, messageID: messageId)

    try await writeAccountProjection(token: mutationToken) { db in

      if var chat = try Chat.fetchOne(db, id: chatId) {
        if chat.lastMsgId == messageId {
          let previousMessage = try Message
            .filter(Column("chatId") == chatId)
            .order(Column("date").desc)
            .limit(1, offset: 1)
            .fetchOne(db)

          chat.lastMsgId = previousMessage?.messageId
          try chat.save(db)
        }
      }

      try Message
        .filter(Column("messageId") == messageId)
        .filter(Column("chatId") == chatId)
        .deleteAll(db)
    }

    Task { @MainActor in
      MessagesPublisher.shared.messagesDeleted(messageIds: [messageId], peer: peerId)
    }
  }

  public func updateTimezone() async throws {
    log.trace("updateTimezone")
    let timeZone = TimeZone.autoupdatingCurrent.identifier
    let mutationToken = try beginAccountMutation()

    do {
      // Update on server
      try auth.validateAccountMutation(mutationToken)
      _ = try await InlineRPCClient.shared.updateSession(timeZone: timeZone)
    } catch {
      log.error("Failed to update timezone", error: error)
      throw error
    }
  }

  public func deleteAttachment(
    externalTask: ExternalTask,
    messageId: Int64,
    chatId: Int64
  ) async throws {
    guard let externalTaskId = externalTask.id else {
      let message = "Missing required data for attachment deletion"
      log.error(message)
      throw NSError(domain: "InlineKit.DataManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    log.info(
      "deleteAttachment requested (externalTaskId: \(externalTaskId), application: \(externalTask.application), messageId: \(messageId), chatId: \(chatId))"
    )

    let target = try await database.reader.read { db -> (Peer, Int64)? in
      guard let message = try Message
        .filter(Column("chatId") == chatId)
        .filter(Column("messageId") == messageId)
        .fetchOne(db),
        let attachment = try Attachment
          .filter(Column("messageId") == message.globalId)
          .filter(Column("externalTaskId") == externalTaskId)
          .fetchOne(db),
        let attachmentID = attachment.attachmentId
      else { return nil }
      return (message.peerId, attachmentID)
    }
    guard let (peerID, attachmentID) = target else {
      throw NSError(
        domain: "InlineKit.DataManager",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Attachment identity is unavailable"]
      )
    }

    try await InlineRPCClient.shared.deleteMessageAttachment(
      peerID: peerID,
      messageID: messageId,
      attachmentID: attachmentID
    )
  }
}
