import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public actor UpdatesEngine: Sendable {
  public static let shared = UpdatesEngine()

  private let database: AppDatabase = .shared
  private let log = Log.scoped("RealtimeUpdates")

  public nonisolated func apply(
    update: InlineProtocol.Update,
    db: Database,
    source: UpdateApplySource,
    reloadPeers: inout Set<Peer>
  ) -> Bool {
    log.trace("apply realtime update")
    // log.debug("Received update type: \(update.update)")

    do {
      switch update.update {
        case let .newMessage(newMessageUpdate):
          log.trace("apply new message update")
          if source == .syncCatchup {
            try newMessageUpdate.apply(
              db,
              publishChanges: false,
              suppressNotifications: true,
              materializeMissingReferences: true
            )
            reloadPeers.insert(newMessageUpdate.message.peerID.toPeer())
          } else {
            try newMessageUpdate.apply(
              db,
              publishChanges: true,
              suppressNotifications: false,
              materializeMissingReferences: true
            )
          }

        case let .updateMessageID(updateMessageId):
          log.trace("apply update message id")
          try updateMessageId.apply(db)

        case let .updateUserStatus(updateUserStatus):
          try updateUserStatus.apply(db)

        case let .updateComposeAction(updateComposeAction):
          updateComposeAction.apply()

        case let .deleteMessages(deleteMessages):
          if source == .syncCatchup {
            try deleteMessages.apply(db, publishChanges: false)
            reloadPeers.insert(deleteMessages.peerID.toPeer())
          } else {
            try deleteMessages.apply(db, publishChanges: true)
          }

        case let .clearChatHistory_p(clearChatHistory):
          if source == .syncCatchup {
            let peers = try clearChatHistory.apply(db, publishChanges: false)
            reloadPeers.formUnion(peers)
          } else {
            try clearChatHistory.apply(db, publishChanges: true)
          }

        case let .messageAttachment(updateMessageAttachment):
          let peer = try updateMessageAttachment.apply(db, publishChanges: source != .syncCatchup)
          if source == .syncCatchup, let peer {
            reloadPeers.insert(peer)
          }

        case let .updateReaction(updateReaction):
          try updateReaction.apply(db)

        case let .deleteReaction(deleteReaction):
          try deleteReaction.apply(db)

        case let .editMessage(editMessage):
          if source == .syncCatchup {
            try editMessage.apply(db, publishChanges: false, materializeMissingReferences: true)
            reloadPeers.insert(editMessage.message.peerID.toPeer())
          } else {
            try editMessage.apply(db, publishChanges: true, materializeMissingReferences: true)
          }

        case let .newChat(newChat):
          try newChat.apply(db)

        case let .deleteChat(deleteChat):
          try deleteChat.apply(db)

        case let .spaceMemberAdd(spaceMemberAdd):
          try spaceMemberAdd.apply(db)

        case let .spaceMemberDelete(spaceMemberDelete):
          try spaceMemberDelete.apply(db)

        case let .spaceMemberUpdate(spaceMemberUpdate):
          try spaceMemberUpdate.apply(db)

        case let .joinSpace(joinSpace):
          try joinSpace.apply(db)

        case let .participantAdd(participantAdd):
          try participantAdd.apply(db)

        case let .participantDelete(participantDelete):
          try participantDelete.apply(db)

        case let .chatVisibility(chatVisibility):
          try chatVisibility.apply(db)

        case let .chatInfo(chatInfo):
          try chatInfo.apply(db)

        case let .chatMoved(chatMoved):
          try chatMoved.apply(db)

        case let .pinnedMessages(pinnedMessages):
          try pinnedMessages.apply(db)

        case let .newMessageNotification(newMessageNotification):
          try newMessageNotification.apply(db)

        case let .updateUserSettings(userSettings):
          userSettings.apply()

        case let .updatedUser(updatedUser):
          try updatedUser.apply(db)

        case .chatSkipPts:
          break

        case let .chatHasNewUpdates(chatHasNewUpdates):
          try chatHasNewUpdates.apply(db)

        case let .markAsUnread(markAsUnread):
          try markAsUnread.apply(db)

        case let .updateReadMaxID(updateReadMaxID):
          try updateReadMaxID.apply(db)

        case let .dialogArchived(dialogArchived):
          try dialogArchived.apply(db)

        case let .dialogNotificationSettings(dialogNotificationSettings):
          try dialogNotificationSettings.apply(db)

        case let .dialogFollowMode(dialogFollowMode):
          try dialogFollowMode.apply(db)

        case let .chatOpen(chatOpen):
          try chatOpen.apply(db)

        case let .messageActionAnswered(messageActionAnswered):
          messageActionAnswered.apply()

        case let .botPresence(botPresence):
          BotPresenceNotifications.post(botPresence)

        default:
          break
      }
      return true
    } catch {
      log.error("Failed to apply update", error: error)
      return false
    }
  }

  @discardableResult
  public func applyBatch(updates: [InlineProtocol.Update]) async -> UpdateApplyResult {
    await applyBatch(updates: updates, source: .realtime)
  }

  @discardableResult
  public func applyBatch(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars? = nil
  ) async -> UpdateApplyResult {
    let batchStartedAt = Date()
    let batchSpan = PerformanceTrace.begin(
      "UpdateApplyBatch",
      category: .updates,
      "source=\(source.traceLabel) updates=\(updates.count) sidecars=\(sidecars?.traceCount ?? 0)"
    )
    log.debug("applying \(updates.count) updates (source=\(source))")
    // Keep catch-up writes bounded so a very large reconnect batch does not monopolize
    // the writer lock long enough to visibly stall chat UI reads.
    let chunkSize = source == .syncCatchup ? 200 : max(updates.count, 1)
    var reloadPeers = Set<Peer>()
    var appliedCount = 0
    var failedCount = 0
    var didApplySidecars = false
    var chunkIndex = 0

    var start = updates.startIndex
    while start < updates.endIndex {
      let end = updates.index(start, offsetBy: chunkSize, limitedBy: updates.endIndex) ?? updates.endIndex
      let chunk = updates[start ..< end]
      let applySidecarsInChunk = !didApplySidecars
      chunkIndex += 1
      let chunkStartedAt = Date()
      let chunkSpan = PerformanceTrace.begin(
        "UpdateApplyChunk",
        category: .updates,
        "source=\(source.traceLabel) chunk=\(chunkIndex) updates=\(chunk.count) sidecars=\(applySidecarsInChunk ? sidecars?.traceCount ?? 0 : 0)"
      )
      var chunkApplied = 0
      var chunkFailed = 0

      do {
        let chunkResult = try await database.dbWriter.write { db in
          if applySidecarsInChunk, let sidecars, hasSidecars(sidecars) {
            let sidecarSpan = PerformanceTrace.begin(
              "UpdateApplySidecars",
              category: .updates,
              "users=\(sidecars.users.count) chats=\(sidecars.chats.count) dialogs=\(sidecars.dialogs.count) spaces=\(sidecars.spaces.count)"
            )
            defer {
              sidecarSpan.end(
                "users=\(sidecars.users.count) chats=\(sidecars.chats.count) dialogs=\(sidecars.dialogs.count) spaces=\(sidecars.spaces.count)"
              )
            }
            try self.apply(sidecars: sidecars, db: db)
          }

          var chunkReloadPeers = Set<Peer>()
          var writeApplied = 0
          var writeFailed = 0
          for update in chunk {
            if self.apply(update: update, db: db, source: source, reloadPeers: &chunkReloadPeers) {
              writeApplied += 1
            } else {
              writeFailed += 1
            }
          }
          return (chunkReloadPeers, writeApplied, writeFailed)
        }
        if applySidecarsInChunk {
          didApplySidecars = true
        }
        reloadPeers.formUnion(chunkResult.0)
        chunkApplied = chunkResult.1
        chunkFailed = chunkResult.2
        appliedCount += chunkApplied
        failedCount += chunkFailed
      } catch {
        log.error("Failed to apply updates chunk", error: error)
        chunkFailed = chunk.count
        failedCount += chunkFailed
      }
      let chunkDurationMs = PerformanceTrace.elapsedMilliseconds(since: chunkStartedAt)
      chunkSpan.end(
        "source=\(source.traceLabel) chunk=\(chunkIndex) applied=\(chunkApplied) failed=\(chunkFailed) reload_peers=\(reloadPeers.count) duration_ms=\(chunkDurationMs)"
      )
      PerformanceTrace.slowBreadcrumb(
        "slow update apply chunk",
        category: "updates.apply",
        durationMs: chunkDurationMs,
        thresholdMs: 250,
        data: [
          "source": source.traceLabel,
          "updates": chunk.count,
          "applied": chunkApplied,
          "failed": chunkFailed,
        ]
      )

      if source == .syncCatchup, end < updates.endIndex {
        await Task.yield()
      }
      start = end
    }

    if source == .syncCatchup, !reloadPeers.isEmpty {
      let reloadStartedAt = Date()
      let reloadSpan = PerformanceTrace.begin(
        "UpdateApplyReloadPublish",
        category: .updates,
        "peers=\(reloadPeers.count)"
      )
      await MainActor.run {
        for peer in reloadPeers {
          MessagesPublisher.shared.messagesReload(peer: peer, animated: false)
        }
      }
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: reloadStartedAt)
      reloadSpan.end("peers=\(reloadPeers.count) duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "slow sync reload publish",
        category: "updates.apply",
        durationMs: durationMs,
        thresholdMs: 150,
        data: [
          "peers": reloadPeers.count,
        ]
      )
    }

    let batchDurationMs = PerformanceTrace.elapsedMilliseconds(since: batchStartedAt)
    batchSpan.end(
      "source=\(source.traceLabel) updates=\(updates.count) chunks=\(chunkIndex) applied=\(appliedCount) failed=\(failedCount) reload_peers=\(reloadPeers.count) duration_ms=\(batchDurationMs)"
    )
    PerformanceTrace.slowBreadcrumb(
      "slow update apply batch",
      category: "updates.apply",
      durationMs: batchDurationMs,
      thresholdMs: source == .syncCatchup ? 750 : 300,
      data: [
        "source": source.traceLabel,
        "updates": updates.count,
        "chunks": chunkIndex,
        "applied": appliedCount,
        "failed": failedCount,
        "reload_peers": reloadPeers.count,
      ]
    )

    return UpdateApplyResult(appliedCount: appliedCount, failedCount: failedCount)
  }

  @discardableResult
  public func applyChatRepair(_ snapshot: ChatRepairSnapshot) async -> Bool {
    guard snapshot.chat.hasChat, snapshot.chat.hasDialog else {
      log.error("Chat repair missing chat or dialog")
      return false
    }

    let peer = snapshot.peer.toPeer()
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "UpdateApplyChatRepair",
      category: .updates,
      "reason=\(snapshot.reason) messages=\(snapshot.history.messages.count)"
    )

    do {
      try await database.dbWriter.write { db in
        var chat = Chat(from: snapshot.chat.chat)
        try self.clearMissingOptionalReferences(in: &chat, db: db)
        try chat.saveWithValidLastMsg(db)

        _ = try snapshot.chat.dialog.saveFull(db)

        if snapshot.chat.hasAnchorMessage {
          _ = try Message.save(
            db,
            protocolMessage: snapshot.chat.anchorMessage,
            publishChanges: false,
            materializeMissingReferences: true
          )
        }

        var savedMessages: [Message] = []
        savedMessages.reserveCapacity(snapshot.history.messages.count)
        for message in snapshot.history.messages {
          let saved = try Message.save(
            db,
            protocolMessage: message,
            publishChanges: false,
            materializeMissingReferences: true
          )
          savedMessages.append(saved)
        }
        try Chat.updateLastMsgIds(db, messages: savedMessages)

        let knownPinnedIds = try self.knownPinnedMessageIds(
          db,
          chatId: snapshot.chat.chat.id,
          messageIds: snapshot.chat.pinnedMessageIds
        )
        try PinnedMessage.replaceAll(db, chatId: snapshot.chat.chat.id, messageIds: knownPinnedIds)
      }

      let reloadStartedAt = Date()
      let reloadSpan = PerformanceTrace.begin(
        "UpdateApplyChatRepairReload",
        category: .updates,
        "reason=\(snapshot.reason)"
      )
      await MainActor.run {
        MessagesPublisher.shared.messagesReload(peer: peer, animated: false)
      }
      let reloadDurationMs = PerformanceTrace.elapsedMilliseconds(since: reloadStartedAt)
      reloadSpan.end("duration_ms=\(reloadDurationMs)")
      PerformanceTrace.slowBreadcrumb(
        "slow chat repair reload publish",
        category: "updates.apply",
        durationMs: reloadDurationMs,
        thresholdMs: 150,
        data: [
          "reason": snapshot.reason,
        ]
      )

      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("success=true duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "slow chat repair apply",
        category: "updates.apply",
        durationMs: durationMs,
        thresholdMs: 400,
        data: [
          "reason": snapshot.reason,
          "messages": snapshot.history.messages.count,
        ]
      )
      return true
    } catch {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("success=false duration_ms=\(durationMs)")
      log.error("Failed to apply chat repair", error: error)
      return false
    }
  }

  private nonisolated func apply(sidecars: InlineProtocol.UpdateSidecars, db: Database) throws {
    for user in sidecars.users {
      _ = try User.save(db, user: user)
    }

    for protoSpace in sidecars.spaces {
      let space = Space(from: protoSpace)
      try space.save(db)
    }

    for var chat in try preparedSidecarChats(sidecars.chats, db: db) {
      try chat.saveWithValidLastMsg(db)
    }

    for dialog in sidecars.dialogs {
      _ = try dialog.saveFull(db)
    }
  }

  private nonisolated func clearMissingOptionalReferences(in chat: inout Chat, db: Database) throws {
    if let spaceId = chat.spaceId, try Space.fetchOne(db, id: spaceId) == nil {
      log.warning("Dropping missing space reference while applying chat repair for chat \(chat.id)")
      chat.spaceId = nil
    }

    if let createdBy = chat.createdBy, try User.fetchOne(db, id: createdBy) == nil {
      log.warning("Dropping missing creator reference while applying chat repair for chat \(chat.id)")
      chat.createdBy = nil
    }

    if let parentChatId = chat.parentChatId, try Chat.fetchOne(db, id: parentChatId) == nil {
      log.warning("Dropping missing parent chat reference while applying chat repair for chat \(chat.id)")
      chat.parentChatId = nil
      chat.parentMessageId = nil
    }
  }

  private nonisolated func knownPinnedMessageIds(
    _ db: Database,
    chatId: Int64,
    messageIds: [Int64]
  ) throws -> [Int64] {
    guard !messageIds.isEmpty else { return [] }

    let known = try Message
      .filter(Message.Columns.chatId == chatId)
      .filter(messageIds.contains(Message.Columns.messageId))
      .fetchAll(db)
    let knownIds = Set(known.map(\.messageId))
    if knownIds.count < messageIds.count {
      log.warning("Skipping unknown pinned message ids while applying chat repair for chat \(chatId)")
    }
    return messageIds.filter(knownIds.contains)
  }
}

// MARK: Extensions

private func hasSidecars(_ sidecars: InlineProtocol.UpdateSidecars) -> Bool {
  !sidecars.users.isEmpty || !sidecars.chats.isEmpty || !sidecars.dialogs.isEmpty || !sidecars.spaces.isEmpty
}

func preparedSidecarChats(_ protoChats: [InlineProtocol.Chat], db: Database) throws -> [Chat] {
  let sidecarChatIds = Set(protoChats.map(\.id))
  return try orderedSidecarChats(protoChats.map(Chat.init)).map { chat in
    var chat = chat
    if let parentChatId = chat.parentChatId,
       !sidecarChatIds.contains(parentChatId),
       try Chat.fetchOne(db, id: parentChatId) == nil {
      chat.parentChatId = nil
      chat.parentMessageId = nil
    }
    return chat
  }
}

private func orderedSidecarChats(_ chats: [Chat]) -> [Chat] {
  var byId: [Int64: Chat] = [:]
  for chat in chats {
    byId[chat.id] = chat
  }
  var sorted: [Chat] = []
  var visiting = Set<Int64>()
  var visited = Set<Int64>()

  func visit(_ chat: Chat) {
    guard !visited.contains(chat.id) else { return }
    guard !visiting.contains(chat.id) else { return }

    visiting.insert(chat.id)
    if let parentChatId = chat.parentChatId, let parent = byId[parentChatId] {
      visit(parent)
    }
    visiting.remove(chat.id)
    visited.insert(chat.id)
    sorted.append(chat)
  }

  for chat in chats {
    visit(chat)
  }

  return sorted
}

private extension UpdateApplySource {
  var traceLabel: String {
    switch self {
      case .realtime:
        "realtime"
      case .syncCatchup:
        "syncCatchup"
    }
  }
}

private extension InlineProtocol.UpdateSidecars {
  var traceCount: Int {
    users.count + chats.count + dialogs.count + spaces.count
  }
}

private enum RealtimeUpdateApplyError: Error {
  case missingChat(Peer)
}

func deleteChatSyncBucket(_ db: Database, chatId: Int64) throws {
  try DbBucketState
    .filter(DbBucketState.Columns.bucketType == 1 && DbBucketState.Columns.entityId == -chatId)
    .deleteAll(db)
}

extension InlineProtocol.UpdateDeleteChat {
  func apply(_ db: Database) throws {
    Log.shared.debug("update delete chat \(peerID.toPeer())")

    let peer = peerID.toPeer()
    guard case let .thread(chatId) = peer else { return }

    try Message.filter(Column("chatId") == chatId).deleteAll(db)
    try Dialog.filter(Column("peerThreadId") == chatId).deleteAll(db)
    try Chat.filter(Column("id") == chatId).deleteAll(db)
    try deleteChatSyncBucket(db, chatId: chatId)

    // Post notification to pop chat route
    Task.detached {
      NotificationCenter.default.post(
        name: Notification.Name("chatDeletedNotification"),
        object: nil,
        userInfo: ["chatId": chatId]
      )
    }
  }
}

extension InlineProtocol.UpdateNewMessage {
  func apply(_ db: Database) throws {
    try apply(db, publishChanges: true, suppressNotifications: false)
  }

  func apply(_ db: Database, publishChanges: Bool, suppressNotifications: Bool) throws {
    try apply(
      db,
      publishChanges: publishChanges,
      suppressNotifications: suppressNotifications,
      materializeMissingReferences: false
    )
  }

  func apply(
    _ db: Database,
    publishChanges: Bool,
    suppressNotifications: Bool,
    materializeMissingReferences: Bool
  ) throws {
    // Avoid double-applying side effects when the same message is replayed (eg. sync catch-up,
    // duplicate delivery, history prefill).
    let hadMessage =
      (try? Message.fetchOne(db, key: ["messageId": message.id, "chatId": message.chatID])) != nil

    let msg = try Message.save(
      db,
      protocolMessage: message,
      publishChanges: publishChanges,
      materializeMissingReferences: materializeMissingReferences
    )

    try Chat.updateLastMsgId(db, chatId: message.chatID, lastMsgId: msg.messageId, date: msg.date)

    // Increase unread count only when this message is newly inserted, not ours,
    // and newer than the dialog's read cursor. This prevents catch-up replays
    // from reintroducing unread state after a read update has already been applied.
    if !hadMessage, msg.out == false, var dialog = try? Dialog.get(peerId: msg.peerId).fetchOne(db) {
      let readInboxMaxId = dialog.readInboxMaxId ?? 0
      if msg.messageId > readInboxMaxId {
        dialog.unreadCount = (dialog.unreadCount ?? 0) + 1
        try dialog.update(db)
      }
    }

    #if os(macOS)
    // Show notifications only for newly-inserted incoming messages, never for catch-up replays.
    if !suppressNotifications, !hadMessage, msg.out == false {
      let dialogSelection = (try? Dialog.get(peerId: msg.peerId).fetchOne(db)?.notificationSelection) ?? .global
      Task { @MainActor in
        let effectiveMode = dialogSelection.resolveEffectiveMode(
          globalMode: INUserSettings.current.notification.mode
        )
        // Realtime newMessage notifications are the "all messages" path.
        guard effectiveMode == .all else { return }
        guard message.sendMode != .modeSilent else { return }
        Task.detached {
          // Handle notification
          await MacNotifications.shared.handleNewMessage(protocolMsg: message)
        }
      }
    }
    #endif
  }
}

extension InlineProtocol.UpdateNewMessageNotification {
  func apply(_ db: Database) throws {
    #if os(macOS)
    // Show notification for incoming messages
    if message.out == false {
      let dialogSelection = (try? Dialog.get(peerId: message.peerID.toPeer()).fetchOne(db)?.notificationSelection)
        ?? .global
      Task { @MainActor in
        let effectiveMode = dialogSelection.resolveEffectiveMode(
          globalMode: INUserSettings.current.notification.mode
        )
        // Explicit notification updates are for mention/important style flows.
        guard effectiveMode != .all && effectiveMode != .none else { return }
        guard message.sendMode != .modeSilent else { return }
        Task.detached {
          // Handle notification
          await MacNotifications.shared.handleNewMessage(protocolMsg: message)
        }
      }
    }
    #endif
  }
}

extension InlineProtocol.UpdateMessageId {
  func apply(_ db: Database) throws {
    Log.shared.debug("update message id \(randomID) \(messageID)")
    let currentUserId = Auth.shared.getCurrentUserId()
    // FIXME: optimize this to update in one go OR to make a faster fetch
    let message = try Message
      .fetchOne(db, key: ["fromId": currentUserId, "randomId": randomID])

    if var message {
      message.status = .sent
      message.messageId = messageID
      message.randomId = nil // should we do this?

      try message
        .saveMessage(
          db,
          onConflict: .replace,
          publishChanges: true
        )

      try Chat.updateLastMsgId(db, chatId: message.chatId, lastMsgId: message.messageId, date: message.date)
    }
  }
}

extension InlineProtocol.UpdateUserStatus {
  func apply(_ db: Database) throws {
    let onlineBoolean: Bool? = switch status.online {
      case .offline:
        false
      case .online:
        true
      default:
        nil
    }

    try User.filter(id: userID).updateAll(
      db,
      [
        Column("online").set(to: onlineBoolean),
        Column("lastOnline").set(to: status.lastOnline.hasDate ? status.lastOnline.date : nil),
      ]
    )
  }
}

extension InlineProtocol.UpdateComposeAction {
  func apply() {
    let action: ApiComposeAction? = switch self.action {
      case .typing:
        .typing
      case .uploadingDocument:
        .uploadingDocument
      case .uploadingPhoto:
        .uploadingPhoto
      case .uploadingVideo:
        .uploadingVideo
      case .recordingVoice:
        ExperimentalFeatureFlags.voiceMessagesEnabled ? .recordingVoice : nil
      default:
        nil
    }

    if let action {
      Task { await ComposeActions.shared.addComposeAction(for: peerID.toPeer(), action: action, userId: userID) }
    } else {
      // cancel - remove action for specific user, not all users
      Task { await ComposeActions.shared.removeComposeAction(for: peerID.toPeer(), userId: userID) }
    }
  }
}

extension InlineProtocol.UpdateDeleteMessages {
  func apply(_ db: Database) throws {
    try apply(db, publishChanges: true)
  }

  func apply(_ db: Database, publishChanges: Bool) throws {
    guard let chat = try Chat.getByPeerId(db: db, peerId: peerID.toPeer()) else {
      Log.shared.error("Failed to find chat for peer \(peerID.toPeer())")
      throw RealtimeUpdateApplyError.missingChat(peerID.toPeer())
    }

    // let chat = try Chat.fetchOne(db, id: chatId)
    let chatId = chat.id
    var prevChatLastMsgId = chat.lastMsgId

    // Delete messages
    for messageId in messageIds {
      // Update last message first
      if prevChatLastMsgId == messageId {
        let previousMessage = try Message
          .filter(Column("chatId") == chat.id)
          .order(Column("date").desc, Column("messageId").desc)
          .limit(1, offset: 1)
          .fetchOne(db)

        var updatedChat = chat
        updatedChat.lastMsgId = previousMessage?.messageId
        try updatedChat.save(db)

        // Track the newly promoted last message so consecutive deletions
        // keep advancing the chat tail correctly.
        prevChatLastMsgId = previousMessage?.messageId
      }

      // TODO: Optimize this to use keys
      try Message
        .filter(Column("messageId") == messageId)
        .filter(Column("chatId") == chatId)
        .deleteAll(db)
    }

    if publishChanges {
      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messagesDeleted(messageIds: messageIds, peer: peerID.toPeer())
      }
    }
  }
}

extension InlineProtocol.UpdateMessageAttachment {
  @discardableResult
  func apply(_ db: Database, publishChanges: Bool = true) throws -> Peer? {
    if attachment.attachment == nil {
      let attachmentId = attachment.id

      if let existing = try Attachment
        .filter(Column("attachmentId") == attachmentId)
        .fetchOne(db)
      {
        if let externalTaskId = existing.externalTaskId {
          try ExternalTask
            .filter(Column("id") == externalTaskId)
            .deleteAll(db)
        }

        if let urlPreviewId = existing.urlPreviewId {
          try UrlPreview
            .filter(Column("id") == urlPreviewId)
            .deleteAll(db)
        }

        try Attachment
          .filter(Column("attachmentId") == attachmentId)
          .deleteAll(db)

        Log.shared.debug("Deleted attachment (attachmentId: \(attachmentId))")
      } else {
        // Legacy fallback: older servers used the externalTaskId as the MessageAttachment.id for deletion updates.
        try Attachment
          .filter(Column("externalTaskId") == attachmentId)
          .deleteAll(db)

        try ExternalTask
          .filter(Column("id") == attachmentId)
          .deleteAll(db)

        Log.shared.debug("Deleted attachment via legacy externalTaskId: \(attachmentId)")
      }
    } else {
      guard attachment.attachment != nil else {
        Log.shared.error("Message attachment is nil")
        return nil
      }

      let message = try Message.filter(Column("messageId") == messageID).filter(Column("chatId") == chatID)
        .fetchOne(db)

      if let message {
        _ = try Attachment.saveWithInnerItems(db, attachment: attachment, messageClientGlobalId: message.globalId!)
        Log.shared.debug("Saved message attachment (attachmentId: \(attachment.id)) for message \(messageID) in chat \(chatID)")
      } else {
        Log.shared.warning("Message not found for attachment update")
      }
    }

    let message = try Message.filter(Column("messageId") == messageID).filter(Column("chatId") == chatID)
      .fetchOne(db)

    if let message {
      if publishChanges {
        db.afterNextTransaction { _ in
          Task(priority: .userInitiated) { @MainActor in
            MessagesPublisher.shared.messageUpdatedSync(message: message, peer: message.peerId, animated: true)
          }
        }
      }
      return message.peerId
    }

    return nil
  }
}

extension InlineProtocol.UpdateReaction {
  func apply(_ db: Database) throws {
    _ = try Reaction.save(db, protocolMessage: reaction)
    let message = try Message
      .filter(Column("messageId") == reaction.messageID)
      .filter(Column("chatId") == reaction.chatID)
      .fetchOne(
        db
      )

    if let message {
      db.afterNextTransaction { _ in
        Task(priority: .userInitiated) { @MainActor in
          MessagesPublisher.shared.messageUpdatedSync(message: message, peer: message.peerId, animated: true)
        }
      }
    }
  }
}

extension InlineProtocol.UpdateDeleteReaction {
  func apply(_ db: Database) throws {
    _ = try Reaction.filter(
      Column("messageId") == messageID
    ).filter(Column("chatId") == chatID)
      .filter(Column("emoji") == emoji)
      .filter(
        Column("userId") == userID
      ).deleteAll(db)

    let message = try Message
      .filter(Column("messageId") == messageID)
      .filter(Column("chatId") == chatID)
      .fetchOne(
        db
      )

    if let message {
      db.afterNextTransaction { _ in
        Task(priority: .userInitiated) { @MainActor in
          MessagesPublisher.shared.messageUpdatedSync(message: message, peer: message.peerId, animated: true)
        }
      }
    }
  }
}

extension InlineProtocol.UpdateEditMessage {
  func apply(_ db: Database) throws {
    try apply(db, publishChanges: true)
  }

  func apply(_ db: Database, publishChanges: Bool, materializeMissingReferences: Bool = false) throws {
    // Delete stale translations for this message since the text has changed
    try Translation
      .filter(Column("messageId") == message.id)
      .filter(Column("chatId") == message.chatID)
      .deleteAll(db)

    _ = try Message.save(
      db,
      protocolMessage: message,
      publishChanges: publishChanges,
      materializeMissingReferences: materializeMissingReferences
    )

    if publishChanges {
      db.afterNextTransaction { _ in
        Task { @MainActor in
          MessagesPublisher.shared.messageUpdatedWithId(
            messageId: message.id,
            chatId: message.chatID,
            peer: message.peerID.toPeer(),
            animated: false
          )
        }
      }
    }
  }
}

extension InlineProtocol.UpdateNewChat {
  func apply(_ db: Database) throws {
    var chat = Chat(from: chat)

    if hasUser {
      Log.shared.debug("saving user \(user)")
      // Save user if it's a private chat
      _ = try User.save(db, user: user)
    }

    Log.shared.debug("saving chat \(chat)")
    try chat.saveWithValidLastMsg(db)

    var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: chat.peerId.toPeer()))
      ?? Dialog(optimisticForChat: chat)
    dialog.chatId = chat.id
    dialog.spaceId = chat.spaceId
    Log.shared.debug("saving dialog \(dialog)")
    try dialog.save(db, onConflict: .replace)
  }
}

extension InlineProtocol.UpdateMessageActionAnswered {
  func apply() {
    let toastText: String? = {
      guard hasUi else { return nil }
      guard case let .toast(toast) = ui.kind else { return nil }
      let trimmed = toast.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }()

    Task { @MainActor in
      MessageActionInteractionState.shared.finish(
        interactionId: interactionID,
        toastText: toastText
      )
    }
  }
}

extension InlineProtocol.UpdateSpaceMemberAdd {
  func apply(_ db: Database) throws {
    _ = try User.save(db, user: user)
    let member = Member(from: member)
    try member.save(db)
  }
}

extension InlineProtocol.UpdateSpaceMemberDelete {
  func apply(_ db: Database) throws {
    Log.shared.debug("update space member delete user \(userID) from space \(spaceID)")

    do {
      // Delete the member from the database
      try Member
        .filter(Column("userId") == userID)
        .filter(Column("spaceId") == spaceID)
        .deleteAll(db)

      // If the removed user is the current user, clean up local data
      if userID == Auth.shared.getCurrentUserId() {
        // Remove all dialogs and chats for this space
        Log.shared.info("Current user was removed from space, cleaning up local data")

        // Run each cleanup step independently so one failure doesn't block the rest.
        func cleanupStep(_ label: String, _ block: () throws -> Void) {
          do {
            try block()
          } catch {
            Log.shared.error("Space cleanup failed: \(label)", error: error)
          }
        }

        // 1. Collect all chats that belong to the removed space
        let chatsInSpace: [Chat] = (try? Chat.filter(Column("spaceId") == spaceID).fetchAll(db)) ?? []
        let chatIds = chatsInSpace.map(\.id)

        // 2. Drop dialogs tied to those chats (both chatId and peerThreadId columns)
        cleanupStep("delete dialogs for chatIds") {
          guard !chatIds.isEmpty else { return }
          try Dialog.filter(chatIds.contains(Column("chatId"))).deleteAll(db)
          try Dialog.filter(chatIds.contains(Column("peerThreadId"))).deleteAll(db)
        }

        // 3. Remove sync bucket state for chats in this space (bucketType = 1)
        cleanupStep("delete sync buckets for chats") {
          guard !chatIds.isEmpty else { return }
          let chatBucketIds = chatIds.map { -$0 } // matches BucketKey.chat entityId encoding
          try DbBucketState
            .filter(DbBucketState.Columns.bucketType == 1 && chatBucketIds.contains(DbBucketState.Columns.entityId))
            .deleteAll(db)
        }

        // 4. Delete any dialogs associated directly with the space (safety)
        cleanupStep("delete dialogs for space") {
          try Dialog.filter(Column("spaceId") == spaceID).deleteAll(db)
        }

        // 5. Remove the chats themselves (cascades will drop messages, reactions, translations, etc.)
        cleanupStep("delete chats in space") {
          try Chat.filter(Column("spaceId") == spaceID).deleteAll(db)
        }

        // 6. Remove all remaining members for this space (if any)
        cleanupStep("delete members in space") {
          try Member.filter(Column("spaceId") == spaceID).deleteAll(db)
        }

        // 7. Remove sync bucket state for the space (bucketType = 3)
        cleanupStep("delete sync bucket for space") {
          try DbBucketState
            .filter(DbBucketState.Columns.bucketType == 3 && DbBucketState.Columns.entityId == spaceID)
            .deleteAll(db)
        }

        // 8. Finally delete the space record
        cleanupStep("delete space record") {
          try Space.filter(Column("id") == spaceID).deleteAll(db)
        }

        // Notify UI so that any views related to this space can be dismissed
        Task.detached {
          NotificationCenter.default.post(
            name: Notification.Name("spaceDeletedNotification"),
            object: nil,
            userInfo: ["spaceId": spaceID]
          )
        }
      }
    } catch {
      Log.shared.error("Failed to delete space member", error: error)
    }
  }
}

extension InlineProtocol.UpdateSpaceMemberUpdate {
  func apply(_ db: Database) throws {
    let updatedMember = Member(from: member)

    let existingMember = try Member
      .filter(Member.Columns.userId == updatedMember.userId)
      .filter(Member.Columns.spaceId == updatedMember.spaceId)
      .fetchOne(db)

    let previousCanAccessPublic = existingMember?.canAccessPublicChats ?? true

    try updatedMember.save(db)

    let currentUserId = Auth.shared.getCurrentUserId()
    if updatedMember.userId == currentUserId,
       previousCanAccessPublic == true,
       updatedMember.canAccessPublicChats == false {
      removePublicThreadsForSpace(spaceId: updatedMember.spaceId, db: db)
    }
  }

  private func removePublicThreadsForSpace(spaceId: Int64, db: Database) {
    func cleanupStep(_ label: String, _ block: () throws -> Void) {
      do { try block() } catch {
        Log.shared.error("Public threads cleanup failed: \(label)", error: error)
      }
    }

    let publicThreads: [Chat] = (try? Chat
      .filter(Chat.Columns.spaceId == spaceId)
      .filter(Chat.Columns.type == ChatType.thread.rawValue)
      .filter(Chat.Columns.isPublic == true)
      .fetchAll(db)) ?? []

    let chatIds = publicThreads.map(\.id)
    guard !chatIds.isEmpty else { return }

    cleanupStep("delete messages for public threads") {
      try Message.filter(chatIds.contains(Column("chatId"))).deleteAll(db)
    }

    cleanupStep("delete dialogs for public threads") {
      try Dialog.filter(chatIds.contains(Column("chatId"))).deleteAll(db)
      try Dialog.filter(chatIds.contains(Column("peerThreadId"))).deleteAll(db)
    }

    cleanupStep("delete sync buckets for public threads") {
      let chatBucketIds = chatIds.map { -$0 }
      try DbBucketState
        .filter(DbBucketState.Columns.bucketType == 1 && chatBucketIds.contains(DbBucketState.Columns.entityId))
        .deleteAll(db)
    }

    cleanupStep("delete public thread chats") {
      try Chat.filter(chatIds.contains(Column("id"))).deleteAll(db)
    }
  }
}

extension InlineProtocol.UpdateJoinSpace {
  func apply(_ db: Database) throws {
    let space = Space(from: space)
    try space.save(db)
    let member = Member(from: member)
    try member.save(db)
  }
}

extension InlineProtocol.UpdateChatParticipantAdd {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat participant add \(chatID) \(participant.userID)")

    ChatParticipant.save(db, from: participant, chatId: chatID)
  }
}

extension InlineProtocol.UpdateChatParticipantDelete {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat participant delete \(chatID) \(userID)")

    try ChatParticipant.filter(Column("chatId") == chatID).filter(Column("userId") == userID).deleteAll(db)

    if userID == Auth.shared.getCurrentUserId() {
      try Message.filter(Column("chatId") == chatID).deleteAll(db)
      try Dialog.filter(Column("peerThreadId") == chatID).deleteAll(db)
      try Chat.filter(Column("id") == chatID).deleteAll(db)
      try deleteChatSyncBucket(db, chatId: chatID)

      // Post notification to pop chat route
      Task.detached {
        NotificationCenter.default.post(
          name: Notification.Name("chatDeletedNotification"),
          object: nil,
          userInfo: ["chatId": chatID]
        )
      }
    }
  }
}

extension InlineProtocol.UpdateChatVisibility {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat visibility \(chatID) public=\(isPublic)")

    if var chat = try Chat.fetchOne(db, id: chatID) {
      chat.isPublic = isPublic
      try chat.save(db)
    }
  }
}

extension InlineProtocol.UpdateChatInfo {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat info \(chatID)")

    if var chat = try Chat.fetchOne(db, id: chatID) {
      if hasTitle {
        chat.title = title
        chat.isUntitled = hasUntitled && untitled ? true : nil
      } else if hasUntitled {
        chat.isUntitled = untitled ? true : nil
      }
      if hasEmoji {
        chat.emoji = emoji.isEmpty ? nil : emoji
      }
      try chat.save(db)
    }
  }
}

extension InlineProtocol.UpdateChatMoved {
  func apply(_ db: Database) throws {
    var updatedChat = Chat(from: chat)
    try updatedChat.saveWithValidLastMsg(db)

    let peer: Peer = .thread(id: updatedChat.id)
    if var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peer)) {
      dialog.spaceId = updatedChat.spaceId
      try dialog.save(db)
    } else {
      let newDialog = Dialog(optimisticForChat: updatedChat)
      try newDialog.save(db, onConflict: .replace)
    }
  }
}

extension InlineProtocol.UpdatePinnedMessages {
  func apply(_ db: Database) throws {
    let peer = peerID.toPeer()
    guard let chat = try Chat.getByPeerId(db: db, peerId: peer) else { return }

    do {
      try PinnedMessage.replaceAll(db, chatId: chat.id, messageIds: messageIds)
    } catch {
      Log.shared.error("Failed to save pinned messages", error: error)
      throw error
    }
  }
}

extension InlineProtocol.UpdateUserSettings {
  func apply() {
    guard hasSettings else { return }

    Task { @MainActor in
      INUserSettings.current.updateFromServer(settings)
    }
  }
}

extension InlineProtocol.UpdateUpdatedUser {
  func apply(_ db: Database) throws {
    _ = try User.save(db, user: user)
  }
}

extension InlineProtocol.UpdateChatHasNewUpdates {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat has new updates \(chatID) \(updateSeq)")

    // Call realtime API to get updates for this chat
  }
}

extension InlineProtocol.UpdateMarkAsUnread {
  func apply(_ db: Database) throws {
    Log.shared.debug("update mark as unread for peer \(peerID.toPeer()) mark: \(unreadMark)")

    // Find the dialog for this peer and update the unread mark
    if var dialog = try Dialog.get(peerId: peerID.toPeer()).fetchOne(db) {
      dialog.unreadMark = unreadMark
      try dialog.update(db)
      Log.shared.debug("Updated dialog unread mark to \(unreadMark)")
    } else {
      Log.shared.warning("Could not find dialog for peer \(peerID.toPeer()) to update unread mark")
    }
  }
}

extension InlineProtocol.UpdateDialogArchived {
  func apply(_ db: Database) throws {
    Log.shared.debug("update dialog archived for peer \(peerID.toPeer()) archived: \(archived)")

    if var dialog = try Dialog.get(peerId: peerID.toPeer()).fetchOne(db) {
      dialog.archived = archived
      try dialog.update(db)
      Log.shared.debug("Updated dialog archived to \(archived)")
    } else {
      Log.shared.warning("Could not find dialog for peer \(peerID.toPeer()) to update archived state")
    }
  }
}

extension InlineProtocol.UpdateDialogNotificationSettings {
  func apply(_ db: Database) throws {
    Log.shared.debug("update dialog notification settings for peer \(peerID.toPeer())")

    if var dialog = try Dialog.get(peerId: peerID.toPeer()).fetchOne(db) {
      dialog.notificationSettings = hasNotificationSettings ? notificationSettings : nil
      try dialog.update(db)
      Log.shared.debug("Updated dialog notification settings")
    } else {
      Log.shared.warning("Could not find dialog for peer \(peerID.toPeer()) to update notification settings")
    }
  }
}

extension InlineProtocol.UpdateDialogFollowMode {
  func apply(_ db: Database) throws {
    Log.shared.debug("update dialog follow mode for peer \(peerID.toPeer())")

    if var dialog = try Dialog.get(peerId: peerID.toPeer()).fetchOne(db) {
      dialog.followMode = hasFollowMode ? followMode : nil
      try dialog.update(db)
      Log.shared.debug("Updated dialog follow mode")
    } else {
      Log.shared.warning("Could not find dialog for peer \(peerID.toPeer()) to update follow mode")
    }
  }
}

extension InlineProtocol.UpdateChatOpen {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat open for chat \(chat.id)")

    if hasUser {
      _ = try User.save(db, user: user)
    }

    var updatedChat = Chat(from: chat)
    try updatedChat.saveWithValidLastMsg(db)
    _ = try dialog.saveFull(db)
  }
}

extension InlineProtocol.UpdateReadMaxId {
  func apply(_ db: Database) throws {
    Log.shared.debug(
      "update read max id for peer \(peerID.toPeer()) readMaxId: \(readMaxID) unreadCount: \(unreadCount)"
    )

    if var dialog = try Dialog.get(peerId: peerID.toPeer()).fetchOne(db) {
      dialog.readInboxMaxId = readMaxID
      dialog.unreadCount = Int(unreadCount)
      dialog.unreadMark = false
      try dialog.update(db)
    } else {
      Log.shared.warning("Could not find dialog for peer \(peerID.toPeer()) to update read state")
    }
  }
}
