import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatsTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .getChats
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var expectedUserBucketState: ExpectedUserBucketState?

    public init(expectedUserBucketState: ExpectedUserBucketState? = nil) {
      self.expectedUserBucketState = expectedUserBucketState
    }
  }

  /// A transaction-safe copy of the user cursor observed immediately before
  /// GET_CHATS was sent. `BucketState` itself is intentionally not Codable.
  public struct ExpectedUserBucketState: Sendable, Codable, Equatable {
    public var date: Int64
    public var seq: Int64

    public init(_ state: BucketState) {
      date = state.date
      seq = state.seq
    }
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/GetChats")

  public init(expectedUserBucketState: BucketState? = nil) {
    context = Context(
      expectedUserBucketState: expectedUserBucketState.map(ExpectedUserBucketState.init)
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChats(.init())
  }

  // MARK: - Transaction Methods

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChats(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace(
      "getChats result counts" +
        " spaces=\(result.spaces.count)" +
        " users=\(result.users.count)" +
        " chats=\(result.chats.count)" +
        " messages=\(result.messages.count)" +
        " folders=\(result.folders.count)" +
        " dialogs=\(result.dialogs.count)"
    )

    // Apply to database/UI

    do {
      let mutationToken = try Auth.shared.handle.beginAccountMutation()
      let span = PerformanceTrace.begin(
        "InitialGetChatsApply",
        category: .launch,
        "spaces=\(result.spaces.count) users=\(result.users.count) chats=\(result.chats.count) messages=\(result.messages.count) folders=\(result.folders.count) dialogs=\(result.dialogs.count)"
      )
      let importResult: SnapshotImportResult
      do {
        importResult = try await AppDatabase.shared.dbWriter.write { db in
          try Auth.shared.handle.validateAccountMutation(mutationToken)
          return try Self.applySnapshot(
            result,
            userProjectionAdmission: context.expectedUserBucketState.map {
              .compareAndSwap(expected: $0)
            } ?? .missingOnly,
            in: db
          )
        }
        span.end("success=1")
      } catch {
        span.end("success=0")
        throw error
      }
      // Ordinary GET_CHATS is catalog-only. It may reconcile actors for truly
      // pristine children seeded by this writer, but must never turn repair
      // targets into an account-wide child sweep. Only two-phase user repair
      // consumes `catchUpTargets`.
      _ = try await Api.realtime.installSnapshotOutcome(
        seededStates: importResult.catalogActorStates,
        catchUpTargets: [:],
        expectedAccount: mutationToken
      )
      Self.report(importResult.userProjectionDisposition)
      Self.report(importResult.failures)
    } catch {
      Log.scoped("GetChatsSnapshot-transaction")
        .error("Failed to apply getChats snapshot", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  static func applySnapshot(
    _ result: InlineProtocol.GetChatsResult,
    userProjectionAdmission: UserProjectionAdmission = .missingOnly,
    replacesActiveCatalog: Bool = false,
    in db: Database
  ) throws -> SnapshotImportResult {
    var seededStates: [BucketKey: BucketState] = [:]
    var catchUpTargets: [BucketKey: Int64] = [:]
    var failures = SnapshotFailureAccumulator()

    // Freeze admission before changing any projection. An absent child is not
    // necessarily new: a newer User removal may have deleted its model/cursor.
    let userProjectionDisposition = try resolveUserProjectionAdmission(
      userProjectionAdmission,
      in: db
    )
    let allowsUserProjectionReplacements = userProjectionDisposition.allowsReplacements
    let userCursor = try DbBucketState
      .filter(DbBucketState.Columns.bucketType == BucketKey.user.getBucket())
      .filter(DbBucketState.Columns.entityId == BucketKey.user.getEntityId())
      .fetchOne(db)
    let allowsPristineChildren = allowsUserProjectionReplacements
      || (userCursor?.seq ?? 0) == 0

    let spaces = deduplicatedSpaces(result.spaces, failures: &failures)
    var chats = deduplicatedChats(result.chats, failures: &failures)
    let chatDependencyUsers = acknowledgementUsers(in: chats)
    if !allowsUserProjectionReplacements {
      chats = chats.map(chatWithoutAcknowledgementUserReplacements)
    }

    // Decide admission from one consistent database view before any
    // child-owned snapshot model is written. A partially populated resource is
    // not a fresh bootstrap: its durable cursor must remain the replay source.
    let spaceAdmissions = try spaceSnapshotAdmissions(spaces, in: db)
    let chatAdmissions = try chatSnapshotAdmissions(chats, in: db)

    for (index, space) in spaces.enumerated() {
      guard let admission = spaceAdmissions[index] else {
        failures.record(.spaces)
        continue
      }
      let sequence = space.hasSeq ? Int64(space.seq) : nil
      guard sequence.map({ $0 >= 0 }) ?? true else {
        failures.record(.spaceCursors)
        continue
      }
      if admission.isPristine && !allowsPristineChildren { continue }

      if replacesActiveCatalog {
        guard let sequence else {
          failures.record(.spaceCursors)
          continue
        }
        guard sequence >= (admission.cursorSequence ?? 0) else {
          if !admission.modelExists { failures.record(.spaces) }
          continue
        }
        if let state = try attempt(.spaces, in: db, failures: &failures, {
          try Space(from: space).save(db)
          return try GRDBSyncStorage.seedSnapshotBucketState(
            for: admission.bucketKey,
            seq: sequence,
            in: db
          )
        }) {
          seededStates[admission.bucketKey] = state
        }
        continue
      }

      let canReconstructMissingModel = !admission.modelExists
        && allowsUserProjectionReplacements
        && sequence != nil && sequence == admission.cursorSequence
      guard admission.isPristine || canReconstructMissingModel else {
        if !admission.modelExists {
          // A cursor without its projection is not caught up. A fresh repair
          // snapshot must certify the exact retained cursor before hydrating
          // it; a latest probe alone would incorrectly accept an empty page.
          failures.record(.spaces)
          continue
        }
        if let sequence {
          recordCatchUpTarget(sequence, for: admission, in: &catchUpTargets)
        } else {
          recordLatestCatchUpTarget(for: admission.bucketKey, in: &catchUpTargets)
        }
        continue
      }

      if let sequence {
        if let state = try attempt(.spaces, in: db, failures: &failures, {
          let spaceModel = Space(from: space)
          try spaceModel.save(db)
          return try GRDBSyncStorage.seedSnapshotBucketState(
            for: admission.bucketKey,
            seq: sequence,
            in: db
          )
        }) {
          if admission.isPristine { seededStates[admission.bucketKey] = state }
        }
      } else {
        recordLatestCatchUpTarget(for: admission.bucketKey, in: &catchUpTargets)
        _ = try attempt(.spaces, in: db, failures: &failures) {
          try Space(from: space).save(db)
          return true
        }
      }
    }

    try importUsers(
      result.users + chatDependencyUsers,
      allowsReplacements: allowsUserProjectionReplacements,
      in: db,
      failures: &failures
    )

    var pendingChats: [PendingChat] = []
    for (index, protocolChat) in chats.enumerated() {
      guard let admission = chatAdmissions[index] else {
        failures.record(.chats)
        continue
      }

      let sequence = protocolChat.hasSeq ? Int64(protocolChat.seq) : nil
      guard sequence.map({ $0 >= 0 }) ?? true else {
        failures.record(.chatCursors)
        continue
      }
      if admission.isPristine && !allowsPristineChildren { continue }

      if replacesActiveCatalog {
        guard let sequence else {
          failures.record(.chatCursors)
          continue
        }
        guard sequence >= (admission.cursorSequence ?? 0) else {
          if !admission.modelExists { failures.record(.chats) }
          continue
        }

        var chat = Chat(from: protocolChat)
        let lastMsgId = chat.lastMsgId
        chat.lastMsgId = nil
        pendingChats.append(PendingChat(
          protocolChat: protocolChat,
          chat: chat,
          lastMsgId: lastMsgId,
          bucketKey: admission.bucketKey,
          bucketSequence: sequence,
          publishesState: true
        ))
        continue
      }

      let canReconstructMissingModel = !admission.modelExists
        && allowsUserProjectionReplacements
        && sequence != nil && sequence == admission.cursorSequence
      guard admission.isPristine || canReconstructMissingModel else {
        if !admission.modelExists {
          failures.record(.chats)
          continue
        }
        // Acknowledgements have their own revision/max monotonicity and remain
        // safe to hydrate without replacing the child-owned Chat model.
        _ = try attempt(.chats, in: db, failures: &failures) {
          try Acknowledgement.save(
            db,
            cursors: protocolChat.acknowledgements.cursors,
            chatId: protocolChat.id,
            publishChanges: true
          )
          return true
        }
        if let sequence {
          recordCatchUpTarget(sequence, for: admission, in: &catchUpTargets)
        } else {
          recordLatestCatchUpTarget(for: admission.bucketKey, in: &catchUpTargets)
        }
        continue
      }

      if sequence == nil {
        recordLatestCatchUpTarget(for: admission.bucketKey, in: &catchUpTargets)
      }

      var chat = Chat(from: protocolChat)
      let lastMsgId = chat.lastMsgId
      chat.lastMsgId = nil
      pendingChats.append(PendingChat(
        protocolChat: protocolChat,
        chat: chat,
        lastMsgId: lastMsgId,
        bucketKey: admission.bucketKey,
        bucketSequence: sequence,
        publishesState: admission.isPristine
      ))
    }

    let snapshotChatIDs = Set(pendingChats.map { $0.chat.id })
    let messagesByChatID = Dictionary(grouping: result.messages, by: \.chatID)
    while !pendingChats.isEmpty {
      var deferredChats: [PendingChat] = []
      var attemptedCount = 0

      for pending in pendingChats {
        if let parentChatId = pending.chat.parentChatId,
           try Chat.fetchOne(db, key: parentChatId) == nil {
          deferredChats.append(pending)
          continue
        }

        attemptedCount += 1
        if let state = try applyPristineChatSnapshot(
          pending,
          messages: messagesByChatID[pending.chat.id] ?? [],
          in: db,
          failures: &failures
        ) {
          if pending.publishesState { seededStates[pending.bucketKey] = state }
        }
      }

      guard attemptedCount > 0 else {
        failures.record(.chats, count: deferredChats.count)
        break
      }
      pendingChats = deferredChats
    }

    let suppressedPristineChatIDs = Set(chats.indices.compactMap { index -> Int64? in
      guard !allowsPristineChildren, chatAdmissions[index]?.isPristine == true else { return nil }
      return chats[index].id
    })
    let insertableMessageChatIDs = Set(chats.indices.compactMap { index -> Int64? in
      guard let admission = chatAdmissions[index], chats[index].hasSeq,
            Int64(chats[index].seq) >= (admission.cursorSequence ?? 0) else { return nil }
      return chats[index].id
    })
    for message in result.messages where !snapshotChatIDs.contains(message.chatID)
      && !suppressedPristineChatIDs.contains(message.chatID) {
      guard message.id > 0, message.chatID > 0 else {
        failures.record(.messages)
        continue
      }
      guard validPeer(message.peerID) else {
        failures.record(.messages)
        continue
      }
      guard try Chat.fetchOne(db, key: message.chatID) != nil else {
        failures.record(.messages)
        continue
      }

      // Revision checks protect an existing row, but a deleted row has no
      // revision left to compare. Only a sequence-certified snapshot may
      // materialize absent rows; stale/unsequenced catalogs cannot resurrect
      // a deletion already consumed by the child cursor.
      if !insertableMessageChatIDs.contains(message.chatID),
         try Message.fetchOne(db, key: ["chatId": message.chatID, "messageId": message.id]) == nil {
        continue
      }

      _ = try attempt(.messages, in: db, failures: &failures, {
        try Message.save(db, protocolMessage: message, publishChanges: false)
      })
    }

    if allowsUserProjectionReplacements {
      for folder in result.folders {
        guard folder.id > 0, !folder.order.isEmpty else {
          failures.record(.folders)
          continue
        }
        _ = try attempt(.folders, in: db, failures: &failures) {
          try folder.saveFull(db)
        }
      }

      for dialog in result.dialogs {
        guard validPeer(dialog.peer) else {
          failures.record(.dialogs)
          continue
        }
        _ = try attempt(.dialogs, in: db, failures: &failures, {
          try dialog.saveFull(
            db,
            preservingExistingReadState: replacesActiveCatalog
          )
          try DialogCatalogStore.include(
            dialogID: Dialog.getDialogId(peerId: dialog.peer.toPeer()),
            in: db
          )
        })
      }
    }

    var retiredBucketKeys: Set<BucketKey> = []
    if allowsUserProjectionReplacements {
      for space in spaces {
        try SpaceCatalogStore.include(spaceID: space.id, in: db)
      }
      if replacesActiveCatalog, failures.reports.isEmpty {
        retiredBucketKeys = try rebuildActiveCatalog(
          spaces: spaces,
          chats: chats,
          dialogs: result.dialogs,
          folders: result.folders,
          messages: result.messages,
          in: db
        )
      }
    }

    return SnapshotImportResult(
      seededStates: seededStates,
      catchUpTargets: catchUpTargets,
      retiredBucketKeys: retiredBucketKeys,
      userProjectionDisposition: userProjectionDisposition,
      failures: failures.reports
    )
  }

  private static func applyPristineChatSnapshot(
    _ pending: PendingChat,
    messages: [InlineProtocol.Message],
    in db: Database,
    failures: inout SnapshotFailureAccumulator
  ) throws -> BucketState? {
    var seededState: BucketState?
    try db.inSavepoint {
      let savedChat: Chat
      do {
        let saved = try pending.chat.saveFull(db)
        try Acknowledgement.save(db, cursors: pending.protocolChat.acknowledgements.cursors, chatId: saved.id, publishChanges: true)
        savedChat = saved
      } catch {
        guard isRecoverableRecordError(error) else { throw error }
        failures.record(.chats)
        return .rollback
      }

      var isComplete = true
      for message in messages {
        guard message.id > 0, message.chatID == savedChat.id else {
          failures.record(.messages)
          isComplete = false
          continue
        }
        guard validPeer(message.peerID) else {
          failures.record(.messages)
          isComplete = false
          continue
        }
        if try attempt(.messages, in: db, failures: &failures, {
          try Message.save(db, protocolMessage: message, publishChanges: false)
        }) == nil {
          isComplete = false
        }
      }

      if let lastMsgId = pending.lastMsgId {
        let hasLastMessage = try Message
          .filter(Column("chatId") == savedChat.id)
          .filter(Column("messageId") == lastMsgId)
          .fetchCount(db) > 0
        if hasLastMessage {
          var updatedChat = savedChat
          updatedChat.lastMsgId = lastMsgId
          if try attempt(.lastMessages, in: db, failures: &failures, {
            try updatedChat.saveFull(db)
          }) == nil {
            isComplete = false
          }
        } else {
          failures.record(.lastMessages)
          isComplete = false
        }
      }

      guard isComplete, let bucketSequence = pending.bucketSequence else {
        return .commit
      }
      do {
        seededState = try GRDBSyncStorage.seedSnapshotBucketState(
          for: pending.bucketKey,
          seq: bucketSequence,
          in: db
        )
        return .commit
      } catch {
        guard isRecoverableRecordError(error) else { throw error }
        failures.record(.chatCursors)
        return .rollback
      }
    }
    return seededState
  }

  /// Telegram-style reset semantics: rebuild active catalog inclusion while
  /// retaining cached Space, Dialog read state, Chat, Message, and File rows.
  private static func rebuildActiveCatalog(
    spaces: [InlineProtocol.Space],
    chats: [InlineProtocol.Chat],
    dialogs: [InlineProtocol.Dialog],
    folders: [InlineProtocol.DialogFolder],
    messages: [InlineProtocol.Message],
    in db: Database
  ) throws -> Set<BucketKey> {
    var retiredBucketKeys = Set<BucketKey>()

    let activeSpaceIDs = Set(spaces.map(\.id))
    for spaceID in try SpaceCatalogStore.replaceActiveSpaceIDs(activeSpaceIDs, in: db) {
      retiredBucketKeys.insert(.space(id: spaceID))
    }

    let activeDialogIDs = Set(dialogs.compactMap { dialog -> Int64? in
      switch dialog.peer.type {
        case let .user(user) where user.userID > 0:
          return Dialog.getDialogId(peerUserId: user.userID)
        case let .chat(chat) where chat.chatID > 0:
          return Dialog.getDialogId(peerThreadId: chat.chatID)
        default:
          return nil
      }
    })
    let activeDialogs = try Dialog.catalogActive().fetchAll(db)
    for dialog in activeDialogs where !activeDialogIDs.contains(dialog.id) {
      if let key = bucketKey(for: dialog) {
        retiredBucketKeys.insert(key)
      }
      try DialogCatalogStore.exclude(dialogID: dialog.id, in: db)
    }

    let activeFolderIDs = Set(folders.map(\.id))
    let cachedFolders = try DialogFolder.fetchAll(db)
    for folder in cachedFolders where !activeFolderIDs.contains(folder.id) {
      try folder.delete(db)
    }

    let messagesByChatID = Dictionary(grouping: messages, by: \.chatID)
    for chat in chats {
      try MessageHistoryCoverageStore.invalidate(db, chatId: chat.id)
      guard let lastMessageID = chat.hasLastMsgID ? Optional(chat.lastMsgID) : nil,
            lastMessageID > 0,
            messagesByChatID[chat.id]?.contains(where: { $0.id == lastMessageID }) == true
      else { continue }
      try MessageHistoryCoverageStore.subtract(
        db,
        chatId: chat.id,
        lowerId: lastMessageID,
        upperId: MessageHistoryHole.positiveMessageIDMax
      )
    }

    return retiredBucketKeys
  }

  private static func bucketKey(for dialog: Dialog) -> BucketKey? {
    if let userID = dialog.peerUserId, userID > 0 {
      return .chat(peer: .with { $0.user = .with { $0.userID = userID } })
    }
    if let chatID = dialog.peerThreadId, chatID > 0 {
      return .chat(peer: .with { $0.chat = .with { $0.chatID = chatID } })
    }
    return nil
  }

  private static func deduplicatedSpaces(
    _ spaces: [InlineProtocol.Space],
    failures: inout SnapshotFailureAccumulator
  ) -> [InlineProtocol.Space] {
    var selected: [Int64: InlineProtocol.Space] = [:]
    var order: [Int64] = []
    for space in spaces {
      guard space.id > 0 else {
        failures.record(.spaces)
        continue
      }
      guard !space.hasSeq || space.seq >= 0 else {
        failures.record(.spaceCursors)
        continue
      }
      guard let existing = selected[space.id] else {
        selected[space.id] = space
        order.append(space.id)
        continue
      }
      if isFresherSnapshot(
        candidateHasSequence: space.hasSeq,
        candidateSequence: space.seq,
        existingHasSequence: existing.hasSeq,
        existingSequence: existing.seq
      ) {
        selected[space.id] = space
      }
    }
    return order.compactMap { selected[$0] }
  }

  private static func deduplicatedChats(
    _ chats: [InlineProtocol.Chat],
    failures: inout SnapshotFailureAccumulator
  ) -> [InlineProtocol.Chat] {
    var selected: [Int64: InlineProtocol.Chat] = [:]
    var order: [Int64] = []
    var conflictingIDs: Set<Int64> = []
    var bucketOwnerIDs: [Int64: Int64] = [:]
    var conflictingBucketIDs: Set<Int64> = []
    for chat in chats {
      guard validChatIdentity(chat) else {
        failures.record(.chats)
        continue
      }
      guard !chat.hasSeq || chat.seq >= 0 else {
        failures.record(.chatCursors)
        continue
      }
      guard !conflictingIDs.contains(chat.id) else { continue }
      let bucketID = BucketKey.chat(peer: chat.peerID).getEntityId()
      guard !conflictingBucketIDs.contains(bucketID) else {
        conflictingIDs.insert(chat.id)
        continue
      }
      guard let existing = selected[chat.id] else {
        if let ownerID = bucketOwnerIDs[bucketID], ownerID != chat.id {
          selected.removeValue(forKey: ownerID)
          conflictingIDs.formUnion([ownerID, chat.id])
          bucketOwnerIDs.removeValue(forKey: bucketID)
          conflictingBucketIDs.insert(bucketID)
          failures.record(.chats)
          continue
        }
        selected[chat.id] = chat
        order.append(chat.id)
        bucketOwnerIDs[bucketID] = chat.id
        continue
      }
      guard samePeerIdentity(existing.peerID, chat.peerID) else {
        let existingBucketID = BucketKey.chat(peer: existing.peerID).getEntityId()
        selected.removeValue(forKey: chat.id)
        if bucketOwnerIDs[existingBucketID] == chat.id {
          bucketOwnerIDs.removeValue(forKey: existingBucketID)
        }
        conflictingIDs.insert(chat.id)
        failures.record(.chats)
        continue
      }
      if isFresherSnapshot(
        candidateHasSequence: chat.hasSeq,
        candidateSequence: chat.seq,
        existingHasSequence: existing.hasSeq,
        existingSequence: existing.seq
      ) {
        selected[chat.id] = chat
      }
    }
    return order.compactMap { conflictingIDs.contains($0) ? nil : selected[$0] }
  }

  private static func isFresherSnapshot(
    candidateHasSequence: Bool,
    candidateSequence: Int32,
    existingHasSequence: Bool,
    existingSequence: Int32
  ) -> Bool {
    if candidateHasSequence != existingHasSequence { return candidateHasSequence }
    guard candidateHasSequence else { return false }
    return candidateSequence > existingSequence
  }

  private static func samePeerIdentity(
    _ lhs: InlineProtocol.Peer,
    _ rhs: InlineProtocol.Peer
  ) -> Bool {
    BucketKey.chat(peer: lhs).getEntityId() == BucketKey.chat(peer: rhs).getEntityId()
  }

  private static func spaceSnapshotAdmissions(
    _ spaces: [InlineProtocol.Space],
    in db: Database
  ) throws -> [ChildSnapshotAdmission?] {
    let ids = Array(Set(spaces.lazy.filter { $0.id > 0 }.map(\.id)))
    let existingIDs = ids.isEmpty
      ? Set<Int64>()
      : Set(try Space.filter(ids.contains(Space.Columns.id)).fetchAll(db).map(\.id))
    let cursorSequences = try bucketCursorSequences(
      bucketType: BucketKey.space(id: 0).getBucket(),
      entityIDs: ids,
      in: db
    )

    return spaces.map { space in
      guard space.id > 0 else { return nil }
      let bucketKey = BucketKey.space(id: space.id)
      let cursorSequence = cursorSequences[bucketKey.getEntityId()]
      return ChildSnapshotAdmission(
        bucketKey: bucketKey,
        isPristine: !existingIDs.contains(space.id) && cursorSequence == nil,
        modelExists: existingIDs.contains(space.id),
        cursorSequence: cursorSequence
      )
    }
  }

  private static func chatSnapshotAdmissions(
    _ chats: [InlineProtocol.Chat],
    in db: Database
  ) throws -> [ChildSnapshotAdmission?] {
    let validChats = chats.filter(validChatIdentity)
    let ids = Array(Set(validChats.map(\.id)))
    let existingIDs = ids.isEmpty
      ? Set<Int64>()
      : Set(try Chat.filter(ids.contains(Chat.Columns.id)).fetchAll(db).map(\.id))
    let entityIDs = Array(Set(validChats.map { BucketKey.chat(peer: $0.peerID).getEntityId() }))
    let cursorSequences = try bucketCursorSequences(
      bucketType: BucketKey.chat(peer: .init()).getBucket(),
      entityIDs: entityIDs,
      in: db
    )

    return chats.map { chat in
      guard validChatIdentity(chat) else { return nil }
      let bucketKey = BucketKey.chat(peer: chat.peerID)
      let cursorSequence = cursorSequences[bucketKey.getEntityId()]
      return ChildSnapshotAdmission(
        bucketKey: bucketKey,
        isPristine: !existingIDs.contains(chat.id) && cursorSequence == nil,
        modelExists: existingIDs.contains(chat.id),
        cursorSequence: cursorSequence
      )
    }
  }

  private static func bucketCursorSequences(
    bucketType: Int,
    entityIDs: [Int64],
    in db: Database
  ) throws -> [Int64: Int64] {
    guard !entityIDs.isEmpty else { return [:] }
    return Dictionary(
      uniqueKeysWithValues: try DbBucketState
        .filter(
          DbBucketState.Columns.bucketType == bucketType
            && entityIDs.contains(DbBucketState.Columns.entityId)
        )
        .fetchAll(db)
        .map { ($0.entityId, $0.seq) }
    )
  }

  private static func recordCatchUpTarget(
    _ sequence: Int64,
    for admission: ChildSnapshotAdmission,
    in targets: inout [BucketKey: Int64]
  ) {
    guard sequence > (admission.cursorSequence ?? 0) else { return }
    guard targets[admission.bucketKey] != 0 else { return }
    targets[admission.bucketKey] = max(
      targets[admission.bucketKey] ?? sequence,
      sequence
    )
  }

  private static func recordLatestCatchUpTarget(
    for bucketKey: BucketKey,
    in targets: inout [BucketKey: Int64]
  ) {
    // Sequence zero is the existing Sync API's request for the latest state,
    // not a durable child cursor.
    targets[bucketKey] = 0
  }

  private static func resolveUserProjectionAdmission(
    _ admission: UserProjectionAdmission,
    in db: Database
  ) throws -> UserProjectionDisposition {
    switch admission {
    case .missingOnly:
      return .missingOnly
    case .alreadyValidated:
      return .applied
    case let .compareAndSwap(expected):
      let record = try DbBucketState
        .filter(
          DbBucketState.Columns.bucketType == BucketKey.user.getBucket()
            && DbBucketState.Columns.entityId == BucketKey.user.getEntityId()
        )
        .fetchOne(db)
      let actual = ExpectedUserBucketState(
        BucketState(date: record?.date ?? 0, seq: record?.seq ?? 0)
      )
      return actual == expected
        ? .applied
        : .superseded(expected: expected, actual: actual)
    }
  }

  private static func importUsers(
    _ users: [InlineProtocol.User],
    allowsReplacements: Bool,
    in db: Database,
    failures: inout SnapshotFailureAccumulator
  ) throws {
    var selected: [Int64: InlineProtocol.User] = [:]
    var order: [Int64] = []
    for user in users {
      guard user.id > 0 else {
        failures.record(.users)
        continue
      }
      guard selected[user.id] == nil else { continue }
      selected[user.id] = user
      order.append(user.id)
    }

    let existingIDs: Set<Int64>
    if allowsReplacements || order.isEmpty {
      existingIDs = []
    } else {
      existingIDs = Set(try User
        .filter(order.contains(User.Columns.id))
        .fetchAll(db)
        .map(\.id))
    }

    for id in order where allowsReplacements || !existingIDs.contains(id) {
      guard let user = selected[id] else { continue }
      _ = try attempt(.users, in: db, failures: &failures) {
        _ = try User.save(db, user: user)
        return true
      }
    }
  }

  private static func acknowledgementUsers(
    in chats: [InlineProtocol.Chat]
  ) -> [InlineProtocol.User] {
    chats.flatMap { chat in
      chat.acknowledgements.cursors.compactMap { cursor in
        guard cursor.hasUser,
              cursor.user.id > 0,
              cursor.user.id == cursor.userID
        else { return nil }
        return cursor.user
      }
    }
  }

  private static func chatWithoutAcknowledgementUserReplacements(
    _ source: InlineProtocol.Chat
  ) -> InlineProtocol.Chat {
    var chat = source
    var acknowledgements = chat.acknowledgements
    acknowledgements.cursors = acknowledgements.cursors.map { sourceCursor in
      var cursor = sourceCursor
      cursor.clearUser()
      return cursor
    }
    chat.acknowledgements = acknowledgements
    return chat
  }

  private static func attempt<T>(
    _ phase: SnapshotImportPhase,
    in db: Database,
    failures: inout SnapshotFailureAccumulator,
    _ body: () throws -> T
  ) throws -> T? {
    do {
      var value: T?
      try db.inSavepoint {
        value = try body()
        return .commit
      }
      return value
    } catch {
      guard isRecoverableRecordError(error) else { throw error }
      failures.record(phase)
      return nil
    }
  }

  static func isRecoverableRecordError(_ error: any Error) -> Bool {
    guard let databaseError = error as? DatabaseError else { return false }
    return databaseError.resultCode == .SQLITE_CONSTRAINT ||
      databaseError.resultCode == .SQLITE_MISMATCH
  }

  private static func validPeer(_ peer: InlineProtocol.Peer) -> Bool {
    switch peer.type {
    case let .user(user): user.userID > 0
    case let .chat(chat): chat.chatID > 0
    case .none: false
    }
  }

  private static func validChatIdentity(_ chat: InlineProtocol.Chat) -> Bool {
    guard chat.id > 0, validPeer(chat.peerID) else { return false }
    if case let .chat(peer) = chat.peerID.type {
      return peer.chatID == chat.id
    }
    return true
  }

  private static func report(_ failures: [SnapshotImportFailure]) {
    for failure in failures {
      Log.scoped("GetChatsSnapshot-\(failure.phase.rawValue)")
        .error("Skipped invalid getChats records", error: failure)
    }
  }

  private static func report(_ disposition: UserProjectionDisposition) {
    guard case let .superseded(expected, actual) = disposition else { return }
    Log.scoped("GetChatsSnapshot-userProjection").warning(
      "Skipped stale user projection expected=(\(expected.date),\(expected.seq)) " +
        "actual=(\(actual.date),\(actual.seq))"
    )
  }

  struct SnapshotImportResult: Sendable {
    var seededStates: [BucketKey: BucketState]
    /// A value of zero requests the exceptional repair caller's latest state.
    var catchUpTargets: [BucketKey: Int64]
    var retiredBucketKeys: Set<BucketKey>
    var userProjectionDisposition: UserProjectionDisposition
    var failures: [SnapshotImportFailure]

    /// The only bucket state ordinary catalog transactions may publish to the
    /// in-memory sync actors. Repair targets deliberately stay excluded.
    var catalogActorStates: [BucketKey: BucketState] { seededStates }
  }

  enum UserProjectionAdmission: Sendable {
    /// Warm/legacy catalogs may hydrate absent dependency users, but never
    /// replace user-bucket-owned rows.
    case missingOnly
    /// Ordinary GET_CHATS may replace the user projection only while the
    /// durable user cursor still exactly matches the preflight observation.
    case compareAndSwap(expected: ExpectedUserBucketState)
    /// The caller already checked the user cursor in this same writer.
    case alreadyValidated
  }

  enum UserProjectionDisposition: Sendable, Equatable {
    case missingOnly
    case applied
    case superseded(
      expected: ExpectedUserBucketState,
      actual: ExpectedUserBucketState
    )

    var allowsReplacements: Bool {
      self == .applied
    }
  }

  struct SnapshotImportFailure:
    Error, Hashable, LocalizedError, PrivacySafeErrorCategoryProviding, Sendable
  {
    var phase: SnapshotImportPhase
    var count: Int

    var errorDescription: String? {
      "getChats skipped \(count) invalid \(phase.rawValue) record(s)"
    }

    var privacySafeErrorCategory: String {
      "snapshot_import:\(phase.rawValue)"
    }
  }

  enum SnapshotImportPhase: String, Hashable, Sendable {
    case spaces
    case spaceCursors
    case users
    case chats
    case messages
    case lastMessages
    case folders
    case dialogs
    case chatCursors
  }

  private struct SnapshotFailureAccumulator {
    private var counts: [SnapshotImportPhase: Int] = [:]

    mutating func record(
      _ phase: SnapshotImportPhase,
      count: Int = 1
    ) {
      counts[phase, default: 0] += count
    }

    var reports: [SnapshotImportFailure] {
      counts.map { phase, count in
        SnapshotImportFailure(phase: phase, count: count)
      }
      .sorted { $0.phase.rawValue < $1.phase.rawValue }
    }
  }

  private struct PendingChat {
    var protocolChat: InlineProtocol.Chat
    var chat: Chat
    var lastMsgId: Int64?
    var bucketKey: BucketKey
    var bucketSequence: Int64?
    var publishesState: Bool
  }

  private struct ChildSnapshotAdmission {
    var bucketKey: BucketKey
    var isPristine: Bool
    var modelExists: Bool
    var cursorSequence: Int64?
  }
}

// Helper

public extension Transaction2 where Self == GetChatsTransaction {
  static func getChats(expectedUserBucketState: BucketState? = nil) -> GetChatsTransaction {
    GetChatsTransaction(expectedUserBucketState: expectedUserBucketState)
  }
}
