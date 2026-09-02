import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public actor UpdatesEngine: Sendable {
  public static let shared = UpdatesEngine()

  private let database: AppDatabase
  private let authenticatedUserID: @Sendable () -> Int64?
  private let validateAccountMutation: @Sendable (AuthAccountMutationToken) throws -> Void
  private let applyUserSettings:
    @MainActor @Sendable (InlineProtocol.UserSettings, Int64, AuthAccountMutationToken) async throws -> Void
  private let applyDeferredEffects: @Sendable ([DeferredUpdateEffect]) async -> Void
  private var userBucketCriticalSectionOwned = false
  private let log = Log.scoped("RealtimeUpdates")

  init(
    database: AppDatabase = .shared,
    authenticatedUserID: @escaping @Sendable () -> Int64? = { Auth.shared.getCurrentUserId() },
    validateAccountMutation: @escaping @Sendable (AuthAccountMutationToken) throws -> Void = {
      try Auth.shared.handle.validateAccountMutation($0)
    },
    applyUserSettings: @escaping @MainActor @Sendable (
      InlineProtocol.UserSettings,
      Int64,
      AuthAccountMutationToken
    ) async throws -> Void = { settings, userID, mutationToken in
      try Auth.shared.handle.validateAccountMutation(mutationToken)
      INUserSettings.current.updateFromServer(settings, receivingUserID: userID)
    },
    applyDeferredEffects: @escaping @Sendable ([DeferredUpdateEffect]) async -> Void = { effects in
      for effect in effects {
        effect.perform()
      }
    }
  ) {
    self.database = database
    self.authenticatedUserID = authenticatedUserID
    self.validateAccountMutation = validateAccountMutation
    self.applyUserSettings = applyUserSettings
    self.applyDeferredEffects = applyDeferredEffects
  }

  private nonisolated func apply(
    update: InlineProtocol.Update,
    db: Database,
    source: UpdateApplySource,
    batchIndex: Int? = nil,
    reloadPeers: inout Set<Peer>,
    deferredEffects: inout [DeferredUpdateEffect]
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
              materializeMissingReferences: true,
              incrementUnreadCount: false
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
          if source != .syncCatchup {
            deferredEffects.append(.composeAction(updateComposeAction))
          }

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

        case let .acknowledgement(cursor):
          let affected = try Acknowledgement.save(
            db, cursors: [cursor], chatId: cursor.chatID,
            publishChanges: source != .syncCatchup, animated: true
          )
          if source == .syncCatchup, !affected.isEmpty,
             let chat = try Chat.fetchOne(db, id: cursor.chatID) {
            reloadPeers.insert(chat.peerId.toPeer())
          }

        case let .updateReaction(updateReaction):
          try updateReaction.apply(db)

        case let .deleteReaction(deleteReaction):
          try deleteReaction.apply(db)

        case let .editMessage(editMessage):
          if source == .syncCatchup {
            let accepted = try editMessage.apply(
              db,
              publishChanges: false,
              materializeMissingReferences: true
            )
            if accepted {
              reloadPeers.insert(editMessage.message.peerID.toPeer())
            }
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

        case let .participantGroupAdd(participantGroupAdd):
          try participantGroupAdd.apply(db)

        case let .participantGroupDelete(participantGroupDelete):
          try participantGroupDelete.apply(db)

        case let .userAddedToChat(userAddedToChat):
          try userAddedToChat.apply(db)

        case let .userRemovedFromChat(userRemovedFromChat):
          try userRemovedFromChat.apply(db)

        case let .chatVisibility(chatVisibility):
          try chatVisibility.apply(db)

        case let .chatInfo(chatInfo):
          try chatInfo.apply(db)

        case let .chatPermissions(chatPermissions):
          try chatPermissions.apply(db)

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

        case let .dialogCollapsedMaxID(dialogCollapsedMaxID):
          try dialogCollapsedMaxID.apply(db)

        case let .dialogFolder(dialogFolder):
          try dialogFolder.apply(db)

        case let .chatOpen(chatOpen):
          let didApply = try chatOpen.apply(db)
          if !didApply {
            log.error(
              "Accounting malformed chatOpen envelope without applying its projection",
              error: DurableUpdateFailure(phase: "chatOpen_envelope", cause: .invalidData)
            )
          }

        case let .messageActionAnswered(messageActionAnswered):
          if source != .syncCatchup {
            deferredEffects.append(.messageActionAnswered(messageActionAnswered))
          }

        case .messageActionInvoked, .spaceSettings:
          // These records are durable so Sync must account for their sequence.
          // Inline's Apple app has no local projection for bot-side action
          // invocations or space grid enablement; the feature owners query their
          // authoritative state when needed.
          break

        case let .botPresence(botPresence):
          if source != .syncCatchup {
            deferredEffects.append(.botPresence(botPresence))
          }

        default:
          break
      }
      return true
    } catch {
      let kind = RealtimeUpdateDiagnostics.kind(of: update.update)
      let reportedError = durableUpdateFailure(error, updateKind: kind)
      #if DEBUG || DEBUG_BUILD
      let batchIndexDescription = batchIndex.map(String.init) ?? "unknown"
      let sequenceDescription = update.hasSeq ? String(update.seq) : "none"
      let dateDescription = update.hasDate ? String(update.date) : "none"
      log.error(
        "Failed to apply update kind=\(kind) source=\(source.traceLabel) " +
          "batch_index=\(batchIndexDescription) " +
          "seq=\(sequenceDescription) date=\(dateDescription) " +
          "payload=\(String(reflecting: update.update)) " +
          "error_debug=\(String(reflecting: error))",
        error: reportedError
      )
      #else
      log.error(
        "Failed to apply update kind=\(kind) source=\(source.traceLabel)",
        error: reportedError
      )
      #endif
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
    sidecars: InlineProtocol.UpdateSidecars? = nil,
    bucketCommit: UpdateBucketCommit? = nil,
    mutationToken: AuthAccountMutationToken? = nil
  ) async -> UpdateApplyResult {
    let receivingUserID = mutationToken?.userID ?? Auth.shared.getCurrentUserId()
    let validateAccountMutation = validateAccountMutation
    let applyUserSettings = applyUserSettings
    let applyDeferredEffects = applyDeferredEffects
    let batchStartedAt = Date()
    let batchSpan = PerformanceTrace.begin(
      "UpdateApplyBatch",
      category: .updates,
      "source=\(source.traceLabel) updates=\(updates.count) sidecars=\(sidecars?.traceCount ?? 0)"
    )
    log.debug("applying \(updates.count) updates (source=\(source))")

    if let bucketCommit, validatedBucketCoordinates(bucketCommit.key) == nil {
      let failedCount = max(updates.count, 1)
      log.error(
        "Refusing update batch with an invalid bucket",
        error: DurableUpdateApplyError.invalidBucket(bucketCommit.key)
      )
      batchSpan.end(
        "source=\(source.traceLabel) updates=\(updates.count) chunks=0 applied=0 failed=\(failedCount) reload_peers=0 duration_ms=0"
      )
      return UpdateApplyResult(appliedCount: 0, failedCount: failedCount)
    }

    let bucketSettingsUpdates: [InlineProtocol.UpdateUserSettings] = updates.compactMap { update in
      guard case let .updateUserSettings(settings) = update.update else {
        return nil
      }
      return settings
    }
    if let bucketCommit,
       !bucketSettingsUpdates.isEmpty,
       (bucketCommit.key != .user || bucketSettingsUpdates.contains(where: { !$0.hasSettings })) {
      let failedCount = max(updates.count, 1)
      log.error(
        "Refusing malformed or non-user bucket settings apply",
        error: DurableUpdateFailure(phase: "batch_settings", cause: .invalidData)
      )
      batchSpan.end(
        "source=\(source.traceLabel) updates=\(updates.count) chunks=0 applied=0 failed=\(failedCount) reload_peers=0 duration_ms=0"
      )
      return UpdateApplyResult(appliedCount: 0, failedCount: failedCount)
    }
    let bucketSettings = bucketCommit == nil ? [] : bucketSettingsUpdates.map(\.settings)
    let isUserBucket = bucketCommit?.key == .user
    let touchesUserProjection = isUserBucket || !bucketSettings.isEmpty
    if touchesUserProjection, userBucketCriticalSectionOwned {
      let failedCount = max(updates.count, 1)
      log.error(
        "Refusing reentrant user-bucket apply during settings repair",
        error: DurableUpdateFailure(phase: "batch_settings_reentrant", cause: .invalidData)
      )
      batchSpan.end(
        "source=\(source.traceLabel) updates=\(updates.count) chunks=0 applied=0 failed=\(failedCount) reload_peers=0 duration_ms=0"
      )
      return UpdateApplyResult(appliedCount: 0, failedCount: failedCount)
    }
    let ownsUserBucketCriticalSection = !bucketSettings.isEmpty
    if ownsUserBucketCriticalSection {
      userBucketCriticalSectionOwned = true
    }
    defer {
      if ownsUserBucketCriticalSection {
        userBucketCriticalSectionOwned = false
      }
    }
    if !bucketSettings.isEmpty {
      guard let mutationToken, let receivingUserID, receivingUserID == mutationToken.userID else {
        let failedCount = max(updates.count, 1)
        log.error(
          "Refusing bucket settings apply without an account mutation token",
          error: DurableUpdateFailure(phase: "batch_settings_auth", cause: .invalidData)
        )
        batchSpan.end(
          "source=\(source.traceLabel) updates=\(updates.count) chunks=0 applied=0 failed=\(failedCount) reload_peers=0 duration_ms=0"
        )
        return UpdateApplyResult(appliedCount: 0, failedCount: failedCount)
      }
      do {
        try validateAccountMutation(mutationToken)
        for settings in bucketSettings {
          try await applyUserSettings(settings, receivingUserID, mutationToken)
        }
      } catch {
        let failedCount = max(updates.count, 1)
        log.error(
          "Refusing bucket settings apply for a stale account generation",
          error: privacySafeDurableApplyError(error, phase: "batch_settings_auth")
        )
        batchSpan.end(
          "source=\(source.traceLabel) updates=\(updates.count) chunks=0 applied=0 failed=\(failedCount) reload_peers=0 duration_ms=0"
        )
        return UpdateApplyResult(appliedCount: 0, failedCount: failedCount)
      }
    }

    // A bucket-owned batch must commit all GRDB model changes and its cursor in one writer
    // transaction. Non-bucket catch-up work keeps the existing bounded chunks so unrelated
    // refreshes do not monopolize the writer lock.
    let chunkSize = bucketCommit != nil
      ? max(updates.count, 1)
      : source == .syncCatchup ? 200 : max(updates.count, 1)
    let userAuthorizedChats = userAuthorizedChatOpenSnapshots(
      in: updates,
      bucketCommit: bucketCommit
    )
    let userAuthorizedChatIDs = userAuthorizedDirectChatIDs(
      in: updates,
      bucketCommit: bucketCommit
    )
    let userAuthorizedDialogPeers = userAuthorizedDialogDependencyPeers(
      in: updates,
      bucketCommit: bucketCommit
    )
    let userAuthorizedSpaceIDs = userAuthorizedJoinSpaceIDs(
      in: updates,
      bucketCommit: bucketCommit
    )
    var reloadPeers = Set<Peer>()
    var appliedCount = 0
    var failedCount = 0
    var committedBucketState: BucketState?
    var didApplySidecars = false
    var chunkIndex = 0

    var start = updates.startIndex
    while start < updates.endIndex {
      let end = updates.index(start, offsetBy: chunkSize, limitedBy: updates.endIndex) ?? updates.endIndex
      let chunk = updates[start ..< end]
      let chunkStartOffset = updates.distance(from: updates.startIndex, to: start)
      let applySidecarsInChunk = !didApplySidecars
      let isFinalChunk = end == updates.endIndex
      let priorFailedCount = failedCount
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
          if let mutationToken {
            try validateAccountMutation(mutationToken)
          }
          if let bucketCommit {
            guard validatedBucketCoordinates(bucketCommit.key) != nil else {
              throw DurableUpdateApplyError.invalidBucket(bucketCommit.key)
            }
            if let expectedStartState = bucketCommit.expectedStartState {
              try requireExpectedBucketState(
                expectedStartState,
                advancingTo: bucketCommit.state,
                for: bucketCommit.key,
                in: db
              )
            }
            try requireUserAdmissionForMissingChild(
              bucketCommit.key, expectedUserState: bucketCommit.expectedUserStateForMissingChild, in: db
            )
          }
          var chunkReloadPeers = Set<Peer>()
          var chunkDeferredEffects: [DeferredUpdateEffect] = []
          if applySidecarsInChunk, let sidecars, hasSidecars(sidecars) {
            let sidecarSpan = PerformanceTrace.begin(
              "UpdateApplySidecars",
              category: .updates,
              "users=\(sidecars.users.count) chats=\(sidecars.chats.count) dialogs=\(sidecars.dialogs.count) spaces=\(sidecars.spaces.count) user_groups=\(sidecars.userGroups.count)"
            )
            defer {
              sidecarSpan.end(
                "users=\(sidecars.users.count) chats=\(sidecars.chats.count) dialogs=\(sidecars.dialogs.count) spaces=\(sidecars.spaces.count) user_groups=\(sidecars.userGroups.count)"
              )
            }
            do {
              try self.apply(
                sidecars: sidecars,
                db: db,
                source: source,
                reloadPeers: &chunkReloadPeers,
                bucketKey: bucketCommit?.key,
                bucketCommit: bucketCommit,
                userAuthorizedChats: userAuthorizedChats,
                userAuthorizedChatIDs: userAuthorizedChatIDs,
                userAuthorizedDialogPeers: userAuthorizedDialogPeers,
                userAuthorizedSpaceIDs: userAuthorizedSpaceIDs
              )
            } catch {
              throw privacySafeDurableApplyError(error, phase: "sidecars")
            }
          }

          var writeApplied = 0
          var writeFailed = 0
          for (offset, update) in chunk.enumerated() {
            if case .updateUserSettings = update.update {
              // This projection is MainActor-owned and is ordered outside this
              // writer. Count the accounted constructor without a DB reducer.
              writeApplied += 1
            } else if self.apply(
              update: update,
              db: db,
              source: source,
              batchIndex: chunkStartOffset + offset,
              reloadPeers: &chunkReloadPeers,
              deferredEffects: &chunkDeferredEffects
            ) {
              writeApplied += 1
            } else {
              if bucketCommit != nil {
                throw DurableUpdateApplyError.reducerFailed(
                  kind: RealtimeUpdateDiagnostics.kind(of: update.update),
                  batchIndex: chunkStartOffset + offset
                )
              }
              writeFailed += 1
            }
          }
          if bucketCommit?.key == .user, let sidecars {
            // A User read reducer can reach the frontier that rejected this
            // count before apply. Recheck only counts in this same writer;
            // structural sidecars and User-owned fields must not replay.
            do {
              try self.applyDialogSidecarCounts(
                sidecars,
                bucketCommit: bucketCommit,
                db: db
              )
            } catch {
              throw privacySafeDurableApplyError(error, phase: "dialog_counts")
            }
          }
          let committedState: BucketState?
          if isFinalChunk,
             priorFailedCount == 0,
             writeFailed == 0,
             let bucketCommit {
            committedState = try GRDBSyncStorage.advanceBucketState(
              for: bucketCommit.key,
              state: bucketCommit.state,
              in: db
            )
          } else {
            committedState = nil
          }
          return (
            chunkReloadPeers,
            writeApplied,
            writeFailed,
            committedState,
            chunkDeferredEffects
          )
        }
        await applyDeferredEffects(chunkResult.4)
        if applySidecarsInChunk {
          didApplySidecars = true
        }
        reloadPeers.formUnion(chunkResult.0)
        chunkApplied = chunkResult.1
        chunkFailed = chunkResult.2
        committedBucketState = chunkResult.3 ?? committedBucketState
        appliedCount += chunkApplied
        failedCount += chunkFailed
        for update in chunk where bucketCommit == nil {
          if case let .updateUserSettings(userSettings) = update.update {
            if let mutationToken, userSettings.hasSettings, let receivingUserID {
              try validateAccountMutation(mutationToken)
              try await applyUserSettings(userSettings.settings, receivingUserID, mutationToken)
            } else {
              await userSettings.apply(receivingUserID: receivingUserID)
            }
          }
        }
      } catch {
        log.error(
          "Failed to apply updates chunk",
          error: privacySafeDurableApplyError(error, phase: "batch")
        )
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

    if updates.isEmpty, let bucketCommit {
      do {
        let result = try await database.dbWriter.write { db in
          if let mutationToken {
            try validateAccountMutation(mutationToken)
          }
          guard validatedBucketCoordinates(bucketCommit.key) != nil else {
            throw DurableUpdateApplyError.invalidBucket(bucketCommit.key)
          }
          if let expectedStartState = bucketCommit.expectedStartState {
            try requireExpectedBucketState(
              expectedStartState,
              advancingTo: bucketCommit.state,
              for: bucketCommit.key,
              in: db
            )
          }
          try requireUserAdmissionForMissingChild(
            bucketCommit.key, expectedUserState: bucketCommit.expectedUserStateForMissingChild, in: db
          )
          var emptyReloadPeers = Set<Peer>()
          if let sidecars, hasSidecars(sidecars) {
            do {
              try self.apply(
                sidecars: sidecars,
                db: db,
                source: source,
                reloadPeers: &emptyReloadPeers,
                bucketKey: bucketCommit.key,
                bucketCommit: bucketCommit
              )
            } catch {
              throw privacySafeDurableApplyError(error, phase: "sidecars")
            }
          }
          let state = try GRDBSyncStorage.advanceBucketState(
            for: bucketCommit.key,
            state: bucketCommit.state,
            in: db
          )
          return (emptyReloadPeers, state)
        }
        reloadPeers.formUnion(result.0)
        committedBucketState = result.1
      } catch {
        log.error(
          "Failed to atomically apply empty update batch sidecars and cursor",
          error: privacySafeDurableApplyError(error, phase: "empty_batch")
        )
        failedCount += 1
      }
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
          MessagesPublisher.shared.messagesReload(
            peer: peer,
            animated: false
          )
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

    return UpdateApplyResult(
      appliedCount: appliedCount,
      failedCount: failedCount,
      committedBucketState: committedBucketState
    )
  }

  @discardableResult
  public func applyChatRepair(_ snapshot: ChatRepairSnapshot) async -> BucketState? {
    guard snapshot.chat.hasChat,
          snapshot.chat.hasDialog,
          let expectedUserID = authenticatedUserID(),
          expectedUserID > 0,
          snapshot.mutationToken.userID == expectedUserID,
          let peer = validatedPeer(snapshot.peer)
    else {
      log.error(
        "Chat repair missing chat or dialog",
        error: DurableUpdateFailure(phase: "chat_repair", cause: .invalidData)
      )
      return nil
    }
    let bucketKey = BucketKey.chat(peer: snapshot.peer)
    guard snapshot.chat.chat.id > 0,
          let responsePeer = validatedPeer(snapshot.chat.chat.peerID),
          responsePeer == peer,
          snapshot.chat.dialog.hasPeer,
          let dialogPeer = validatedPeer(snapshot.chat.dialog.peer),
          dialogPeer == peer,
          snapshot.chat.dialog.hasChatID,
          snapshot.chat.dialog.chatID == snapshot.chat.chat.id
    else {
      log.error(
        "Chat repair snapshot peer does not match the requested bucket",
        error: DurableUpdateFailure(phase: "chat_repair", cause: .invalidData)
      )
      return nil
    }
    guard snapshot.chat.chat.hasSeq,
          Int64(snapshot.chat.chat.seq) >= snapshot.targetState.seq
    else {
      log.error(
        "Chat repair snapshot sequence is below the frozen recovery target",
        error: DurableUpdateFailure(phase: "chat_repair", cause: .invalidData)
      )
      return nil
    }
    let pinnedIDs = snapshot.chat.pinnedMessageIds
    let hydratedPinnedIDs = snapshot.pinnedMessages.map(\.id)
    let recentMessages = snapshot.chat.messages
    guard pinnedIDs.allSatisfy({ $0 > 0 }),
          Set(pinnedIDs).count == pinnedIDs.count,
          Set(hydratedPinnedIDs).count == hydratedPinnedIDs.count,
          Set(hydratedPinnedIDs).isSubset(of: Set(pinnedIDs)),
          snapshot.pinnedMessages.allSatisfy({
            $0.id > 0 &&
              $0.chatID == snapshot.chat.chat.id &&
              validatedPeer($0.peerID) == peer
          }),
          recentMessages.count <= 100,
          Set(recentMessages.map(\.id)).count == recentMessages.count,
          recentMessages.allSatisfy({
            $0.id > 0 &&
              $0.chatID == snapshot.chat.chat.id &&
              validatedPeer($0.peerID) == peer
          }),
          zip(recentMessages, recentMessages.dropFirst()).allSatisfy({ $0.0.id > $0.1.id }),
          snapshot.chat.chat.hasLastMsgID
            ? recentMessages.first?.id == snapshot.chat.chat.lastMsgID
            : recentMessages.isEmpty
    else {
      log.error(
        "Chat repair snapshot is invalid",
        error: DurableUpdateFailure(phase: "chat_repair", cause: .invalidData)
      )
      return nil
    }

    let startedAt = Date()
    let validateAccountMutation = validateAccountMutation
    let span = PerformanceTrace.begin(
      "UpdateApplyChatRepair",
      category: .updates,
      "reason=\(snapshot.reason) messages=\(recentMessages.count) pins=\(snapshot.pinnedMessages.count)"
    )

    do {
      try validateAccountMutation(snapshot.mutationToken)
      let committedState = try await database.dbWriter.write { db in
        try validateAccountMutation(snapshot.mutationToken)
        try requireUserAdmissionForMissingChild(
          bucketKey, expectedUserState: snapshot.expectedUserStateForMissingChild, in: db
        )
        if let existing = try DbBucketState
          .filter(
            DbBucketState.Columns.bucketType == bucketKey.getBucket()
              && DbBucketState.Columns.entityId == bucketKey.getEntityId()
          )
          .fetchOne(db),
          existing.seq >= Int64(snapshot.chat.chat.seq) {
          if try Chat.fetchOne(db, id: snapshot.chat.chat.id) != nil {
            return BucketState(date: existing.date, seq: existing.seq)
          }
          guard existing.seq == Int64(snapshot.chat.chat.seq) else {
            throw DurableUpdateApplyError.cursorRegression(
              bucket: bucketKey,
              expected: .init(date: existing.date, seq: existing.seq),
              proposed: .init(date: snapshot.targetState.date, seq: Int64(snapshot.chat.chat.seq))
            )
          }
        }

        let chatID = snapshot.chat.chat.id

        if snapshot.chat.hasUser {
          _ = try User.save(db, user: snapshot.chat.user)
        }
        var chat = Chat(from: snapshot.chat.chat)
        let authoritativeLastMessageID = chat.lastMsgId
        chat.participantRosterComplete = false
        if snapshot.chat.hasAnchorMessage {
          let anchor = snapshot.chat.anchorMessage
          guard let parentChatID = chat.parentChatId,
                let parentMessageID = chat.parentMessageId,
                anchor.id == parentMessageID,
                anchor.chatID == parentChatID,
                validatedPeer(anchor.peerID) != nil
          else {
            throw DurableUpdateApplyError.invalidParentReference(chatID: chat.id)
          }
          _ = try Message.save(
            db,
            protocolMessage: anchor,
            publishChanges: false,
            materializeMissingReferences: true
          )
        }
        try self.requireStructuralReferences(for: chat, db: db)
        try chat.saveWithValidLastMsg(db)
        try Acknowledgement.save(db, cursors: snapshot.chat.chat.acknowledgements.cursors, chatId: chat.id)

        let dialogID = Dialog.getDialogId(peerId: peer)
        if try Dialog.fetchOne(db, id: dialogID) == nil {
          _ = try snapshot.chat.dialog.saveFull(db)
        }

        for message in recentMessages {
          _ = try Message.save(
            db,
            protocolMessage: message,
            publishChanges: false,
            materializeMissingReferences: true
          )
        }

        for pinnedMessage in snapshot.pinnedMessages {
          _ = try Message.save(
            db,
            protocolMessage: pinnedMessage,
            publishChanges: false,
            materializeMissingReferences: true
          )
        }

        // Repair proves current chat metadata and the exact pin rows, not any
        // older history interval. Preserve cached messages, certify the newest
        // ordinary-message window, and leave only the older range demand-driven.
        try MessageHistoryCoverageStore.invalidate(db, chatId: chatID)
        if let oldestRecentID = recentMessages.last?.id {
          try MessageHistoryCoverageStore.subtract(
            db,
            chatId: chatID,
            lowerId: oldestRecentID,
            upperId: MessageHistoryHole.positiveMessageIDMax
          )
        }

        // The first save may have withheld lastMsgId until its message row was
        // materialized. Re-apply the same authoritative Chat after the window.
        chat.lastMsgId = authoritativeLastMessageID
        try chat.saveWithValidLastMsg(db)

        try PinnedMessage.replaceAll(
          db,
          chatId: chatID,
          messageIds: snapshot.chat.pinnedMessageIds
        )

        return try GRDBSyncStorage.advanceBucketState(
          for: bucketKey,
          state: BucketState(
            date: snapshot.targetState.date,
            seq: Int64(snapshot.chat.chat.seq)
          ),
          in: db
        )
      }

      let reloadStartedAt = Date()
      let reloadSpan = PerformanceTrace.begin(
        "UpdateApplyChatRepairReload",
        category: .updates,
        "reason=\(snapshot.reason)"
      )
      await MainActor.run {
        MessagesPublisher.shared.messagesReload(
          peer: peer,
          animated: false
        )
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
          "pins": pinnedIDs.count,
          "hydrated_pins": snapshot.pinnedMessages.count,
        ]
      )
      return committedState
    } catch {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("success=false duration_ms=\(durationMs)")
      log.error(
        "Failed to apply chat repair",
        error: privacySafeDurableApplyError(error, phase: "chat_repair")
      )
      return nil
    }
  }

  @discardableResult
  public func applySpaceRepair(_ repair: SpaceRepairSnapshot) async -> BucketState? {
    let snapshot = repair.snapshot
    guard snapshot.hasSpace,
          snapshot.hasMembership,
          let expectedUserID = authenticatedUserID(),
          expectedUserID > 0,
          repair.mutationToken.userID == expectedUserID,
          repair.spaceID > 0,
          snapshot.membership.id > 0,
          snapshot.membership.userID == expectedUserID,
          snapshot.space.id == repair.spaceID,
          snapshot.membership.spaceID == repair.spaceID,
          snapshot.space.hasSeq,
          Int64(snapshot.space.seq) >= repair.targetState.seq
    else {
      log.error(
        "Space repair snapshot is incomplete or below the frozen recovery target",
        error: DurableUpdateFailure(phase: "space_repair", cause: .invalidData)
      )
      return nil
    }

    let bucketKey = BucketKey.space(id: repair.spaceID)
    let validateAccountMutation = validateAccountMutation
    do {
      try validateAccountMutation(repair.mutationToken)
      return try await database.dbWriter.write { db in
        try validateAccountMutation(repair.mutationToken)
        try requireUserAdmissionForMissingChild(
          bucketKey, expectedUserState: repair.expectedUserStateForMissingChild, in: db
        )
        if let existing = try DbBucketState
          .filter(
            DbBucketState.Columns.bucketType == bucketKey.getBucket()
              && DbBucketState.Columns.entityId == bucketKey.getEntityId()
          )
          .fetchOne(db),
          existing.seq >= Int64(snapshot.space.seq) {
          if try Space.fetchOne(db, id: repair.spaceID) != nil {
            return BucketState(date: existing.date, seq: existing.seq)
          }
          guard existing.seq == Int64(snapshot.space.seq) else {
            throw DurableUpdateApplyError.cursorRegression(
              bucket: bucketKey,
              expected: .init(date: existing.date, seq: existing.seq),
              proposed: .init(date: repair.targetState.date, seq: Int64(snapshot.space.seq))
            )
          }
        }

        var space = Space(from: snapshot.space)
        space.memberRosterComplete = false
        try space.save(db)
        try Member(from: snapshot.membership).save(db)
        try SpaceCatalogStore.include(spaceID: repair.spaceID, in: db)
        if snapshot.hasSettings {
          try SpaceRecoverySettings(spaceId: repair.spaceID, settings: snapshot.settings).save(db)
        }

        return try GRDBSyncStorage.advanceBucketState(
          for: bucketKey,
          state: BucketState(
            date: repair.targetState.date,
            seq: Int64(snapshot.space.seq)
          ),
          in: db
        )
      }
    } catch {
      log.error(
        "Failed to apply space repair",
        error: privacySafeDurableApplyError(error, phase: "space_repair")
      )
      return nil
    }
  }

  @discardableResult
  public func applyUserRepair(_ repair: UserRepairSnapshot) async -> UserRepairOutcome? {
    let replayWindowIsValid: Bool
    if repair.replacesActiveCatalog {
      replayWindowIsValid = repair.replayThroughState.map {
        $0.date > 0 && $0.seq >= repair.checkpointState.seq
      } ?? false
    } else {
      replayWindowIsValid = repair.replayThroughState == nil
    }
    guard repair.me.hasUser,
          let expectedUserID = authenticatedUserID(),
          expectedUserID > 0,
          repair.me.user.id == expectedUserID,
          repair.mutationToken.userID == expectedUserID,
          repair.checkpointState.date > 0,
          repair.checkpointState.seq >= repair.targetState.seq,
          replayWindowIsValid
    else {
      log.error(
        "User repair snapshot identity or checkpoint is invalid",
        error: DurableUpdateFailure(phase: "user_repair", cause: .invalidData)
      )
      return nil
    }
    guard !userBucketCriticalSectionOwned else {
      log.error(
        "Refusing reentrant user repair during a user-bucket apply",
        error: DurableUpdateFailure(phase: "user_repair_reentrant", cause: .invalidData)
      )
      return nil
    }
    userBucketCriticalSectionOwned = true
    defer { userBucketCriticalSectionOwned = false }

    let bucketKey = BucketKey.user
    let validateAccountMutation = validateAccountMutation
    let applyUserSettings = applyUserSettings
    do {
      try validateAccountMutation(repair.mutationToken)
      let expectedCursor = try await database.reader.read { db in
        DurableBucketAdmissionState(try DbBucketState
          .filter(
            DbBucketState.Columns.bucketType == bucketKey.getBucket()
              && DbBucketState.Columns.entityId == bucketKey.getEntityId()
          )
          .fetchOne(db))
      }
      let checkpointAlreadyReached = expectedCursor.state.seq >= repair.checkpointState.seq
      if checkpointAlreadyReached, !repair.requiresProjectionAudit {
        return .superseded(
          currentState: expectedCursor.state,
          replayThroughState: repair.replayThroughState
        )
      }

      if !checkpointAlreadyReached {
        guard repair.settings.hasUserSettings else {
          log.error(
            "User repair snapshot is missing required settings",
            error: DurableUpdateFailure(phase: "user_repair_settings", cause: .invalidData)
          )
          return nil
        }
        try await applyUserSettings(
          repair.settings.userSettings,
          expectedUserID,
          repair.mutationToken
        )
      }

      return try await database.dbWriter.write { db in
        try validateAccountMutation(repair.mutationToken)
        let currentCursor = DurableBucketAdmissionState(try DbBucketState
          .filter(
            DbBucketState.Columns.bucketType == bucketKey.getBucket()
              && DbBucketState.Columns.entityId == bucketKey.getEntityId()
          )
          .fetchOne(db))
        guard currentCursor == expectedCursor else {
          return .superseded(
            currentState: currentCursor.state,
            replayThroughState: repair.replayThroughState
          )
        }

        // A regression audit may finish after live user events passed the
        // checkpoint it fetched. Audit child evidence without overwriting
        // those newer user-owned rows at a cursor that replay already passed.
        let userProjectionIsCurrent = currentCursor.state.seq <= repair.checkpointState.seq
        let imported = try GetChatsTransaction.applySnapshot(
          repair.chats,
          userProjectionAdmission: userProjectionIsCurrent ? .alreadyValidated : .missingOnly,
          replacesActiveCatalog: repair.replacesActiveCatalog && userProjectionIsCurrent,
          in: db
        )
        guard imported.failures.isEmpty else {
          throw TransactionExecutionError.invalid
        }
        if userProjectionIsCurrent {
          _ = try User.save(db, user: repair.me.user)
        }
        let proposedUserState = checkpointAlreadyReached
          ? expectedCursor.state
          : repair.checkpointState
        if imported.catchUpTargets.isEmpty {
          let state: BucketState
          if checkpointAlreadyReached {
            state = currentCursor.state
          } else {
            state = try GRDBSyncStorage.advanceBucketState(
              for: bucketKey,
              state: repair.checkpointState,
              in: db
            )
          }
          return .applied(
            state: state,
            seededStates: imported.seededStates,
            replayThroughState: repair.replayThroughState,
            retiredBucketKeys: imported.retiredBucketKeys
          )
        }
        return .pending(
          finalization: UserRepairFinalization(
            expectedUserState: expectedCursor.state,
            expectedUserStateExists: expectedCursor.exists,
            proposedUserState: proposedUserState,
            replayThroughState: repair.replayThroughState,
            catchUpTargets: imported.catchUpTargets,
            retiredBucketKeys: imported.retiredBucketKeys,
            mutationToken: repair.mutationToken
          ),
          seededStates: imported.seededStates
        )
      }
    } catch {
      log.error(
        "Failed to apply user repair",
        error: privacySafeDurableApplyError(error, phase: "user_repair")
      )
      return nil
    }
  }

  @discardableResult
  public func finalizeUserRepair(
    _ finalization: UserRepairFinalization,
    resolvedTargets: [BucketKey: UserRepairTargetResolution]
  ) async -> BucketState? {
    guard let expectedUserID = authenticatedUserID(),
          expectedUserID > 0,
          finalization.mutationToken.userID == expectedUserID,
          finalization.proposedUserState.date > 0,
          finalization.proposedUserState.seq >= finalization.expectedUserState.seq,
          !finalization.catchUpTargets.isEmpty,
          Set(resolvedTargets.keys) == Set(finalization.catchUpTargets.keys),
          finalization.catchUpTargets.allSatisfy({ key, requestedSequence in
            guard key != .user,
                  validatedBucketCoordinates(key) != nil,
                  requestedSequence >= 0,
                  let resolution = resolvedTargets[key],
                  resolution.state.seq >= 0
            else { return false }
            return requestedSequence == 0
              ? resolution.authoritative
              : resolution.state.seq >= requestedSequence
          })
    else {
      log.error(
        "Refusing invalid user repair finalization",
        error: DurableUpdateFailure(phase: "user_repair_finalize", cause: .invalidData)
      )
      return nil
    }
    guard !userBucketCriticalSectionOwned else {
      log.error(
        "Refusing reentrant user repair finalization",
        error: DurableUpdateFailure(phase: "user_repair_finalize_reentrant", cause: .invalidData)
      )
      return nil
    }
    userBucketCriticalSectionOwned = true
    defer { userBucketCriticalSectionOwned = false }

    let validateAccountMutation = validateAccountMutation
    do {
      try validateAccountMutation(finalization.mutationToken)
      return try await database.dbWriter.write { db in
        try validateAccountMutation(finalization.mutationToken)
        guard try User.fetchOne(db, id: expectedUserID) != nil else {
          throw DurableUpdateApplyError.unresolvedUserRepairAccount(expectedUserID)
        }
        let currentUserCursor = DurableBucketAdmissionState(try DbBucketState
          .filter(
            DbBucketState.Columns.bucketType == BucketKey.user.getBucket()
              && DbBucketState.Columns.entityId == BucketKey.user.getEntityId()
          )
          .fetchOne(db))
        let cursorAlreadyFinalized =
          currentUserCursor.state.seq >= finalization.proposedUserState.seq
        let expectedCursor = DurableBucketAdmissionState(
          exists: finalization.expectedUserStateExists,
          state: finalization.expectedUserState
        )
        guard cursorAlreadyFinalized || currentUserCursor == expectedCursor else {
          throw DurableUpdateApplyError.cursorChanged(
            bucket: .user,
            expected: expectedCursor.state,
            actual: currentUserCursor.state
          )
        }

        for (key, targetSequence) in finalization.catchUpTargets {
          guard let resolution = resolvedTargets[key],
                let coordinates = validatedBucketCoordinates(key)
          else {
            throw DurableUpdateApplyError.unresolvedUserRepairTarget(key)
          }
          let durableTarget = DurableBucketAdmissionState(try DbBucketState
            .filter(
              DbBucketState.Columns.bucketType == coordinates.bucket
                && DbBucketState.Columns.entityId == coordinates.entityID
            )
            .fetchOne(db))
          guard durableTarget.exists,
                durableTarget.state.seq >= max(targetSequence, resolution.state.seq),
                durableTarget.state.date >= resolution.state.date
          else {
            throw DurableUpdateApplyError.unresolvedUserRepairTarget(key)
          }
        }
        if cursorAlreadyFinalized {
          return currentUserCursor.state
        }

        return try GRDBSyncStorage.advanceBucketState(
          for: .user,
          state: finalization.proposedUserState,
          in: db
        )
      }
    } catch {
      log.error(
        "Failed to finalize user repair",
        error: privacySafeDurableApplyError(error, phase: "user_repair_finalize")
      )
      return nil
    }
  }

  private nonisolated func apply(
    sidecars: InlineProtocol.UpdateSidecars,
    db: Database,
    source: UpdateApplySource,
    reloadPeers: inout Set<Peer>,
    bucketKey: BucketKey? = nil,
    bucketCommit: UpdateBucketCommit? = nil,
    userAuthorizedChats: [Int64: InlineProtocol.Chat] = [:],
    userAuthorizedChatIDs: Set<Int64> = [],
    userAuthorizedDialogPeers: Set<Peer> = [],
    userAuthorizedSpaceIDs: Set<Int64> = []
  ) throws {
    for user in sidecars.users {
      _ = try User.save(db, user: user)
    }

    let chatSnapshots = Dictionary(sidecars.chats.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    var exactChatRoots = userAuthorizedChats
    if case let .chat(bucketPeer) = bucketKey,
       let ownerPeer = validatedPeer(bucketPeer),
       let snapshot = sidecars.chats.last(where: { validatedPeer($0.peerID) == ownerPeer }) {
      exactChatRoots[snapshot.id] = snapshot
    }
    var directChatRoots = userAuthorizedChatIDs
    directChatRoots.formUnion(userAuthorizedDialogSidecarChatIDs(
      sidecars: sidecars,
      authorizedPeers: userAuthorizedDialogPeers
    ))
    let authorizedChatIDs = userAuthorizedSidecarChatIDs(
      sidecars: sidecars.chats,
      exactRoots: exactChatRoots,
      idRoots: directChatRoots
    )
    let authorizedSpaceDependencies = Set(sidecars.chats.compactMap { chat in
      authorizedChatIDs.contains(chat.id) && chat.hasSpaceID ? chat.spaceID : nil
    })
    var authorizedSpaceIDs = userAuthorizedSpaceIDs
    if case let .space(id) = bucketKey {
      authorizedSpaceIDs.insert(id)
    }
    for protoSpace in sidecars.spaces {
      try saveMissingSidecarSpace(
        protoSpace,
        db: db,
        allowBehindRetainedCursor: authorizedSpaceIDs.contains(protoSpace.id) ||
          authorizedSpaceDependencies.contains(protoSpace.id)
      )
    }

    for userGroup in sidecars.userGroups {
      guard try sidecarUserGroupDependenciesExist(userGroup, db: db) else { continue }
      try UserGroup.save(db, from: userGroup)
    }

    for chat in try preparedSidecarChats(sidecars.chats, db: db) {
      guard let snapshot = chatSnapshots[chat.id] else { continue }
      try saveMissingSidecarChat(
        snapshot,
        preparedChat: chat,
        db: db,
        allowBehindRetainedCursor: authorizedChatIDs.contains(snapshot.id)
      )
    }

    for chat in sidecars.chats {
      guard try Chat.fetchOne(db, id: chat.id) != nil else { continue }
      let affected = try Acknowledgement.save(
        db, cursors: chat.acknowledgements.cursors, chatId: chat.id,
        publishChanges: source != .syncCatchup
      )
      if source == .syncCatchup, !affected.isEmpty {
        reloadPeers.insert(chat.peerID.toPeer())
      }
    }

    for dialog in sidecars.dialogs {
      guard let peer = validatedPeer(dialog.peer) else {
        throw DurableUpdateApplyError.invalidBucket(.chat(peer: dialog.peer))
      }
      if try Dialog.get(peerId: peer).fetchOne(db) == nil,
         try sidecarDialogDependenciesExist(dialog, db: db) {
        _ = try dialog.saveFull(db)
      }
    }
    try applyDialogSidecarCounts(sidecars, bucketCommit: bucketCommit, db: db)
  }

  private nonisolated func applyDialogSidecarCounts(
    _ sidecars: InlineProtocol.UpdateSidecars,
    bucketCommit: UpdateBucketCommit?,
    db: Database
  ) throws {
    let chatSnapshots = Dictionary(sidecars.chats.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    for dialog in sidecars.dialogs {
      guard let peer = validatedPeer(dialog.peer),
            var existing = try Dialog.get(peerId: peer).fetchOne(db) else { continue }
      // Enrichment has no User-bucket sequence. Never let a delayed Chat page
      // undo newer archive/read/open/folder state owned by that bucket. Its
      // count is usable only for the same read frontier and exact Chat
      // sequence covered by this page. A future count would include messages
      // that are still buffered and would be counted again on live delivery.
      guard dialog.hasUnreadCount, dialog.unreadCount >= 0,
            dialog.hasReadMaxID, dialog.readMaxID >= 0,
            dialog.readMaxID == max(0, existing.readInboxMaxId ?? 0),
            dialog.hasChatID, existing.chatId == dialog.chatID,
            let snapshot = chatSnapshots[dialog.chatID],
            validatedPeer(snapshot.peerID) == peer,
            let chat = try Chat.fetchOne(db, id: dialog.chatID),
            validatedPeer(chat.peerId) == peer,
            snapshot.hasSeq, snapshot.seq >= 0,
            let coveredSequence = try dialogCountCoveredSequence(
              for: snapshot.peerID,
              bucketCommit: bucketCommit,
              db: db
            ),
            Int64(snapshot.seq) == coveredSequence else { continue }
      existing.unreadCount = Int(dialog.unreadCount)
      try existing.update(db)
    }
  }

  private nonisolated func requireStructuralReferences(for chat: Chat, db: Database) throws {
    if let spaceId = chat.spaceId, try Space.fetchOne(db, id: spaceId) == nil {
      throw DurableUpdateApplyError.unresolvedSpace(chatID: chat.id, spaceID: spaceId)
    }

    if let createdBy = chat.createdBy, try User.fetchOne(db, id: createdBy) == nil {
      throw DurableUpdateApplyError.unresolvedCreator(chatID: chat.id, userID: createdBy)
    }

    guard (chat.parentChatId == nil) == (chat.parentMessageId == nil) else {
      throw DurableUpdateApplyError.invalidParentReference(chatID: chat.id)
    }

    if let parentChatId = chat.parentChatId, let parentMessageId = chat.parentMessageId {
      guard parentChatId > 0,
            parentMessageId > 0,
            parentChatId != chat.id,
            try Chat.fetchOne(db, id: parentChatId) != nil
      else {
        throw DurableUpdateApplyError.unresolvedParentChat(
          chatID: chat.id,
          parentChatID: parentChatId
        )
      }
      guard try Message
        .filter(Message.Columns.chatId == parentChatId)
        .filter(Message.Columns.messageId == parentMessageId)
        .fetchCount(db) > 0
      else {
        throw DurableUpdateApplyError.unresolvedParentMessage(
          chatID: chat.id,
          parentChatID: parentChatId,
          parentMessageID: parentMessageId
        )
      }
    }
  }

}

// MARK: Extensions

enum RealtimeUpdateDiagnostics {
  static func kind(of update: InlineProtocol.Update.OneOf_Update?) -> String {
    guard let update else { return "missing" }
    switch update {
    case .newMessage: return "newMessage"
    case .acknowledgement: return "acknowledgement"
    case .editMessage: return "editMessage"
    case .updateMessageID: return "updateMessageID"
    case .deleteMessages: return "deleteMessages"
    case .updateComposeAction: return "updateComposeAction"
    case .updateUserStatus: return "updateUserStatus"
    case .messageAttachment: return "messageAttachment"
    case .updateReaction: return "updateReaction"
    case .deleteReaction: return "deleteReaction"
    case .participantAdd: return "participantAdd"
    case .participantDelete: return "participantDelete"
    case .newChat: return "newChat"
    case .deleteChat: return "deleteChat"
    case .spaceMemberAdd: return "spaceMemberAdd"
    case .spaceMemberDelete: return "spaceMemberDelete"
    case .joinSpace: return "joinSpace"
    case .updateReadMaxID: return "updateReadMaxID"
    case .updateUserSettings: return "updateUserSettings"
    case .newMessageNotification: return "newMessageNotification"
    case .markAsUnread: return "markAsUnread"
    case .chatSkipPts: return "chatSkipPts"
    case .chatHasNewUpdates: return "chatHasNewUpdates"
    case .spaceHasNewUpdates: return "spaceHasNewUpdates"
    case .spaceMemberUpdate: return "spaceMemberUpdate"
    case .chatVisibility: return "chatVisibility"
    case .dialogArchived: return "dialogArchived"
    case .chatInfo: return "chatInfo"
    case .pinnedMessages: return "pinnedMessages"
    case .chatMoved: return "chatMoved"
    case .dialogNotificationSettings: return "dialogNotificationSettings"
    case .chatOpen: return "chatOpen"
    case .messageActionInvoked: return "messageActionInvoked"
    case .messageActionAnswered: return "messageActionAnswered"
    case .clearChatHistory_p: return "clearChatHistory"
    case .botPresence: return "botPresence"
    case .dialogFollowMode: return "dialogFollowMode"
    case .updatedUser: return "updatedUser"
    case .participantGroupAdd: return "participantGroupAdd"
    case .participantGroupDelete: return "participantGroupDelete"
    case .userAddedToChat: return "userAddedToChat"
    case .userRemovedFromChat: return "userRemovedFromChat"
    case .spaceSettings: return "spaceSettings"
    case .chatPermissions: return "chatPermissions"
    case .dialogCollapsedMaxID: return "dialogCollapsedMaxID"
    case .dialogFolder: return "dialogFolder"
    }
  }
}

private func hasSidecars(_ sidecars: InlineProtocol.UpdateSidecars) -> Bool {
  !sidecars.users.isEmpty ||
    !sidecars.chats.isEmpty ||
    !sidecars.dialogs.isEmpty ||
    !sidecars.spaces.isEmpty ||
    !sidecars.userGroups.isEmpty
}

private func userAuthorizedChatOpenSnapshots(
  in updates: [InlineProtocol.Update],
  bucketCommit: UpdateBucketCommit?
) -> [Int64: InlineProtocol.Chat] {
  guard bucketCommit?.key == .user else { return [:] }

  var chats: [Int64: InlineProtocol.Chat] = [:]
  for update in updates {
    guard case let .chatOpen(chatOpen) = update.update,
          isValidChatOpenEnvelope(chatOpen)
    else { continue }
    chats[chatOpen.chat.id] = chatOpen.chat
  }
  return chats
}

private func isValidChatOpenEnvelope(_ chatOpen: InlineProtocol.UpdateChatOpen) -> Bool {
  guard chatOpen.hasChat,
        chatOpen.hasDialog,
        chatOpen.chat.id > 0,
        chatOpen.chat.hasPeerID,
        let chatPeer = validatedPeer(chatOpen.chat.peerID),
        chatOpen.dialog.hasPeer,
        validatedPeer(chatOpen.dialog.peer) == chatPeer,
        chatOpen.dialog.hasChatID,
        chatOpen.dialog.chatID == chatOpen.chat.id,
        chatOpen.chat.hasSpaceID == chatOpen.dialog.hasSpaceID,
        !chatOpen.chat.hasSpaceID || chatOpen.chat.spaceID == chatOpen.dialog.spaceID
  else { return false }

  if case let .thread(id) = chatPeer, id != chatOpen.chat.id {
    return false
  }
  if chatOpen.hasUser {
    guard case let .user(id) = chatPeer, chatOpen.user.id == id else { return false }
  }
  return true
}

private func userAuthorizedDirectChatIDs(
  in updates: [InlineProtocol.Update],
  bucketCommit: UpdateBucketCommit?
) -> Set<Int64> {
  guard bucketCommit?.key == .user else { return [] }
  return Set(updates.compactMap { update in
    let chatID: Int64? = switch update.update {
      case let .userAddedToChat(access): access.chatID
      case let .participantAdd(participant): participant.chatID
      case let .participantGroupAdd(participant): participant.chatID
      case let .chatPermissions(permissions): permissions.chatID
      default: nil
    }
    guard let chatID, chatID > 0 else { return nil }
    return chatID
  })
}

private func userAuthorizedDialogDependencyPeers(
  in updates: [InlineProtocol.Update],
  bucketCommit: UpdateBucketCommit?
) -> Set<Peer> {
  guard bucketCommit?.key == .user else { return [] }
  var peers = Set<Peer>()
  for update in updates {
    switch update.update {
      case let .dialogArchived(value):
        if let peer = validatedPeer(value.peerID) { peers.insert(peer) }
      case let .updateReadMaxID(value):
        if let peer = validatedPeer(value.peerID) { peers.insert(peer) }
      case let .markAsUnread(value):
        if let peer = validatedPeer(value.peerID) { peers.insert(peer) }
      case let .dialogNotificationSettings(value):
        if let peer = validatedPeer(value.peerID) { peers.insert(peer) }
      case let .dialogFollowMode(value):
        if let peer = validatedPeer(value.peerID) { peers.insert(peer) }
      case let .dialogCollapsedMaxID(value):
        if let peer = validatedPeer(value.peerID) { peers.insert(peer) }
      case let .dialogFolder(value):
        for dialog in value.dialogs {
          if let peer = validatedPeer(dialog.peer) { peers.insert(peer) }
        }
      default:
        break
    }
  }
  return peers
}

private func userAuthorizedDialogSidecarChatIDs(
  sidecars: InlineProtocol.UpdateSidecars,
  authorizedPeers: Set<Peer>
) -> Set<Int64> {
  guard !authorizedPeers.isEmpty else { return [] }
  let chats = Dictionary(sidecars.chats.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
  return Set(sidecars.dialogs.compactMap { dialog in
    guard dialog.hasChatID, dialog.chatID > 0,
          let peer = validatedPeer(dialog.peer), authorizedPeers.contains(peer),
          let chat = chats[dialog.chatID], validatedPeer(chat.peerID) == peer
    else { return nil }
    return dialog.chatID
  })
}

private func userAuthorizedJoinSpaceIDs(
  in updates: [InlineProtocol.Update],
  bucketCommit: UpdateBucketCommit?
) -> Set<Int64> {
  guard bucketCommit?.key == .user else { return [] }
  return Set(updates.compactMap { update in
    guard case let .joinSpace(join) = update.update,
          join.space.id > 0,
          join.member.spaceID == join.space.id
    else { return nil }
    return join.space.id
  })
}

private func userAuthorizedSidecarChatIDs(
  sidecars: [InlineProtocol.Chat],
  exactRoots: [Int64: InlineProtocol.Chat],
  idRoots: Set<Int64>
) -> Set<Int64> {
  guard !exactRoots.isEmpty || !idRoots.isEmpty else { return [] }
  let snapshots = Dictionary(sidecars.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
  var admitted = Set<Int64>()

  for (id, root) in exactRoots {
    guard let snapshot = snapshots[id],
          validatedPeer(snapshot.peerID) == validatedPeer(root.peerID)
    else { continue }
    admitted.insert(id)
  }
  for id in idRoots {
    guard let snapshot = snapshots[id], validatedPeer(snapshot.peerID) != nil else { continue }
    admitted.insert(id)
  }

  var pending = Array(admitted)
  while let id = pending.popLast(),
        let snapshot = snapshots[id],
        snapshot.hasParentChatID,
        snapshot.parentChatID > 0,
        let parent = snapshots[snapshot.parentChatID],
        validatedPeer(parent.peerID) == .thread(id: parent.id),
        admitted.insert(parent.id).inserted {
    pending.append(parent.id)
  }
  return admitted
}

enum DurableUpdateFailureCause: String, Sendable {
  case missingEntity = "missing_entity"
  case foreignKey = "foreign_key"
  case uniqueConstraint = "unique_constraint"
  case notNullConstraint = "not_null_constraint"
  case checkConstraint = "check_constraint"
  case otherConstraint = "other_constraint"
  case databaseBusy = "database_busy"
  case databaseCorrupt = "database_corrupt"
  case invalidData = "invalid_data"
  case other = "other"
}

struct DurableUpdateFailure: Error, Sendable, PrivacySafeErrorCategoryProviding {
  let phase: String
  let cause: DurableUpdateFailureCause

  var privacySafeErrorCategory: String {
    "sync_apply:\(phase):\(cause.rawValue)"
  }
}

func durableUpdateFailure(_ error: Error, updateKind: String) -> DurableUpdateFailure {
  DurableUpdateFailure(phase: updateKind, cause: durableUpdateFailureCause(error))
}

private func privacySafeDurableApplyError(_ error: Error, phase: String) -> Error {
  if error is any PrivacySafeErrorCategoryProviding {
    return error
  }
  return DurableUpdateFailure(phase: phase, cause: durableUpdateFailureCause(error))
}

private func durableUpdateFailureCause(_ error: Error) -> DurableUpdateFailureCause {
  if error is RealtimeUpdateApplyError || error is AcknowledgementPersistenceError {
    return .missingEntity
  }
  guard let databaseError = error as? DatabaseError else { return .other }
  switch databaseError.extendedResultCode {
    case .SQLITE_CONSTRAINT_FOREIGNKEY:
      return .foreignKey
    case .SQLITE_CONSTRAINT_UNIQUE, .SQLITE_CONSTRAINT_PRIMARYKEY:
      return .uniqueConstraint
    case .SQLITE_CONSTRAINT_NOTNULL:
      return .notNullConstraint
    case .SQLITE_CONSTRAINT_CHECK:
      return .checkConstraint
    case .SQLITE_BUSY, .SQLITE_LOCKED:
      return .databaseBusy
    case .SQLITE_CORRUPT, .SQLITE_NOTADB:
      return .databaseCorrupt
    case .SQLITE_MISMATCH:
      return .invalidData
    default:
      return databaseError.resultCode == .SQLITE_CONSTRAINT ? .otherConstraint : .other
  }
}

enum DurableUpdateApplyError: Error, PrivacySafeErrorCategoryProviding {
  case reducerFailed(kind: String, batchIndex: Int)
  case invalidBucket(BucketKey)
  case cursorChanged(bucket: BucketKey, expected: BucketState, actual: BucketState)
  case cursorRegression(bucket: BucketKey, expected: BucketState, proposed: BucketState)
  case unresolvedSpace(chatID: Int64, spaceID: Int64)
  case unresolvedCreator(chatID: Int64, userID: Int64)
  case unresolvedParentChat(chatID: Int64, parentChatID: Int64)
  case unresolvedParentMessage(chatID: Int64, parentChatID: Int64, parentMessageID: Int64)
  case invalidParentReference(chatID: Int64)
  case unresolvedUserRepairAccount(Int64)
  case unresolvedUserRepairTarget(BucketKey)

  var privacySafeErrorCategory: String {
    switch self {
      case let .reducerFailed(kind, _):
        "sync_apply:reducer_failed:\(kind)"
      case .invalidBucket:
        "sync_apply:invalid_bucket"
      case .cursorChanged:
        "sync_apply:cursor_changed"
      case .cursorRegression:
        "sync_apply:cursor_regression"
      case .unresolvedSpace:
        "sync_apply:unresolved_space"
      case .unresolvedCreator:
        "sync_apply:unresolved_creator"
      case .unresolvedParentChat:
        "sync_apply:unresolved_parent_chat"
      case .unresolvedParentMessage:
        "sync_apply:unresolved_parent_message"
      case .invalidParentReference:
        "sync_apply:invalid_parent_reference"
      case .unresolvedUserRepairAccount:
        "sync_apply:unresolved_user_repair_account"
      case .unresolvedUserRepairTarget:
        "sync_apply:unresolved_user_repair_target"
    }
  }
}

enum DeferredUpdateEffect: Sendable {
  case composeAction(InlineProtocol.UpdateComposeAction)
  case messageActionAnswered(InlineProtocol.UpdateMessageActionAnswered)
  case botPresence(InlineProtocol.UpdateBotPresence)

  nonisolated func perform() {
    switch self {
      case let .composeAction(update):
        update.apply()
      case let .messageActionAnswered(update):
        update.apply()
      case let .botPresence(update):
        BotPresenceNotifications.post(update)
    }
  }
}

private func requireExpectedBucketState(
  _ expected: BucketState,
  advancingTo proposed: BucketState,
  for key: BucketKey,
  in db: Database
) throws {
  guard let coordinates = validatedBucketCoordinates(key) else {
    throw DurableUpdateApplyError.invalidBucket(key)
  }
  let record = try DbBucketState
    .filter(
      DbBucketState.Columns.bucketType == coordinates.bucket
        && DbBucketState.Columns.entityId == coordinates.entityID
    )
    .fetchOne(db)
  let actual = BucketState(date: record?.date ?? 0, seq: record?.seq ?? 0)
  guard actual.date == expected.date, actual.seq == expected.seq else {
    throw DurableUpdateApplyError.cursorChanged(
      bucket: key,
      expected: expected,
      actual: actual
    )
  }
  guard proposed.seq >= expected.seq else {
    throw DurableUpdateApplyError.cursorRegression(
      bucket: key,
      expected: expected,
      proposed: proposed
    )
  }
}

private func requireUserAdmissionForMissingChild(
  _ key: BucketKey,
  expectedUserState: BucketState?,
  in db: Database
) throws {
  guard let expectedUserState else { return }
  let isMissing: Bool
  switch key {
    case let .chat(peer):
      guard let peer = validatedPeer(peer) else { throw DurableUpdateApplyError.invalidBucket(key) }
      isMissing = try Chat.getByPeerId(db: db, peerId: peer) == nil
    case let .space(id):
      isMissing = try Space.fetchOne(db, id: id) == nil
    case .user:
      return
  }
  guard isMissing else { return }
  // Absence at seq=0 is ambiguous: it can be pristine or a User removal that
  // committed while the first child page was in flight. The request-time User
  // cursor disambiguates without a durable tombstone or an account-wide sweep.
  try requireExpectedBucketState(expectedUserState, advancingTo: expectedUserState, for: .user, in: db)
}

private func validatedPeer(_ protoPeer: InlineProtocol.Peer) -> Peer? {
  switch protoPeer.type {
    case let .user(value) where value.userID > 0:
      .user(id: value.userID)
    case let .chat(value) where value.chatID > 0:
      .thread(id: value.chatID)
    default:
      nil
  }
}

private func validatedBucketCoordinates(
  _ key: BucketKey
) -> (bucket: Int, entityID: Int64)? {
  switch key {
    case .user:
      return (2, 0)
    case let .space(id) where id > 0:
      return (3, id)
    case let .chat(peer):
      guard let peer = validatedPeer(peer) else { return nil }
      switch peer {
        case let .user(id): return (1, id)
        case let .thread(id): return (1, -id)
      }
    default:
      return nil
  }
}

private struct DurableBucketAdmissionState: Equatable, Sendable {
  let exists: Bool
  let state: BucketState

  init(exists: Bool, state: BucketState) {
    self.exists = exists
    self.state = state
  }

  init(_ record: DbBucketState?) {
    exists = record != nil
    state = BucketState(date: record?.date ?? 0, seq: record?.seq ?? 0)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.exists == rhs.exists &&
      lhs.state.date == rhs.state.date &&
      lhs.state.seq == rhs.state.seq
  }
}

// Foreign-bucket snapshots supply missing structural references, not a second
// projection owner. In particular, do not put an old model behind a retained
// cursor: replay would then have no reason to restore the overwritten fields.
private func admitsSidecarSnapshot(sequence: Int64?, for key: BucketKey, db: Database) throws -> Bool {
  guard let coordinates = validatedBucketCoordinates(key),
        sequence.map({ $0 >= 0 }) ?? true else { return false }
  let cursor = try DbBucketState
    .filter(
      DbBucketState.Columns.bucketType == coordinates.bucket
        && DbBucketState.Columns.entityId == coordinates.entityID
    )
    .fetchOne(db)
  guard let cursor, cursor.seq > 0 else { return true }
  return sequence.map { $0 >= cursor.seq } ?? false
}

private func dialogCountCoveredSequence(
  for snapshotPeer: InlineProtocol.Peer,
  bucketCommit: UpdateBucketCommit?,
  db: Database
) throws -> Int64? {
  if let bucketCommit,
     case let .chat(bucketPeer) = bucketCommit.key,
     validatedPeer(bucketPeer) == validatedPeer(snapshotPeer) {
    return bucketCommit.state.seq
  }
  guard let coordinates = validatedBucketCoordinates(.chat(peer: snapshotPeer)) else {
    return nil
  }
  return try DbBucketState
    .filter(
      DbBucketState.Columns.bucketType == coordinates.bucket
        && DbBucketState.Columns.entityId == coordinates.entityID
    )
    .fetchOne(db)?
    .seq
}

private func saveMissingSidecarSpace(
  _ snapshot: InlineProtocol.Space,
  db: Database,
  allowBehindRetainedCursor: Bool = false
) throws {
  guard try Space.fetchOne(db, id: snapshot.id) == nil,
        try (allowBehindRetainedCursor || admitsSidecarSnapshot(
          sequence: snapshot.hasSeq ? Int64(snapshot.seq) : nil,
          for: .space(id: snapshot.id),
          db: db
        )) else { return }
  try Space(from: snapshot).save(db)
}

private func saveMissingSidecarChat(
  _ snapshot: InlineProtocol.Chat,
  preparedChat: Chat,
  db: Database,
  allowBehindRetainedCursor: Bool = false
) throws {
  guard snapshot.id > 0, let peer = validatedPeer(snapshot.peerID),
        peer == validatedPeer(preparedChat.peerId),
        try Chat.fetchOne(db, id: snapshot.id) == nil,
        try (allowBehindRetainedCursor || admitsSidecarSnapshot(
          sequence: snapshot.hasSeq ? Int64(snapshot.seq) : nil,
          for: .chat(peer: snapshot.peerID),
          db: db
        )) else { return }
  var chat = preparedChat
  try chat.saveWithValidLastMsg(db)
}

private func sidecarUserGroupDependenciesExist(
  _ group: InlineProtocol.UserGroup,
  db: Database
) throws -> Bool {
  guard group.id > 0, group.spaceID > 0,
        try Space.fetchOne(db, id: group.spaceID) != nil
  else { return false }
  for userID in group.userIds {
    if try (userID <= 0 || User.fetchOne(db, id: userID) == nil) {
      return false
    }
  }
  return true
}

private func sidecarDialogDependenciesExist(
  _ dialog: InlineProtocol.Dialog,
  db: Database
) throws -> Bool {
  guard let peer = validatedPeer(dialog.peer) else { return false }
  switch peer {
    case let .user(id):
      guard try User.fetchOne(db, id: id) != nil else { return false }
    case let .thread(id):
      guard try Chat.fetchOne(db, id: id) != nil else { return false }
  }
  if dialog.hasChatID, try Chat.fetchOne(db, id: dialog.chatID) == nil {
    return false
  }
  return true
}

func preparedSidecarChats(_ protoChats: [InlineProtocol.Chat], db: Database) throws -> [Chat] {
  let sidecarChatIds = Set(protoChats.map(\.id))
  return try orderedSidecarChats(protoChats.map(Chat.init)).map { chat in
    var chat = chat
    chat.participantRosterComplete = try Chat.fetchOne(db, id: chat.id)?.participantRosterComplete ?? false
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
    users.count + chats.count + dialogs.count + spaces.count + userGroups.count
  }
}

enum RealtimeUpdateApplyError: Error {
  case missingChat(Peer)
}

func deleteChatSyncBucket(_ db: Database, chatId: Int64) throws {
  try DbBucketState
    .filter(DbBucketState.Columns.bucketType == 1 && DbBucketState.Columns.entityId == -chatId)
    .deleteAll(db)
}

func deleteLocalChatData(_ db: Database, chatId: Int64) throws {
  // `chat(id, lastMsgId)` is a composite foreign key to
  // `message(chatId, messageId)`. Its SET NULL action would otherwise try to
  // clear the chat's primary key when the referenced last message is deleted.
  try Chat
    .filter(Chat.Columns.id == chatId)
    .updateAll(db, [Chat.Columns.lastMsgId.set(to: nil)])
  try Message.filter(Column("chatId") == chatId).deleteAll(db)
  try Dialog.filter(Column("chatId") == chatId).deleteAll(db)
  try Dialog.filter(Column("peerThreadId") == chatId).deleteAll(db)
  try Chat.filter(Column("id") == chatId).deleteAll(db)
  try deleteChatSyncBucket(db, chatId: chatId)

  db.afterNextTransaction { _ in
    Task.detached {
      NotificationCenter.default.post(
        name: Notification.Name("chatDeletedNotification"),
        object: nil,
        userInfo: ["chatId": chatId]
      )
    }
  }
}

private func deleteLocalPrivateThreadIfCurrentUserLostAccess(_ db: Database, chatId: Int64) throws {
  guard let chat = try Chat.fetchOne(db, id: chatId) else { return }
  guard chat.type == .thread, chat.isPublic != true else { return }
  guard try !currentUserHasLocalAccess(db, chatId: chatId) else { return }

  try deleteLocalChatData(db, chatId: chatId)
}

private func currentUserHasLocalAccess(_ db: Database, chatId: Int64) throws -> Bool {
  let currentUserId = Auth.shared.getCurrentUserId()

  let directGrantCount = try ChatParticipant
    .filter(ChatParticipant.Columns.chatId == chatId)
    .filter(ChatParticipant.Columns.userId == currentUserId)
    .fetchCount(db)
  if directGrantCount > 0 {
    return true
  }

  let remainingGroupIds = try ChatParticipantGroup
    .filter(ChatParticipantGroup.Columns.chatId == chatId)
    .fetchAll(db)
    .map(\.groupId)
  guard !remainingGroupIds.isEmpty else { return false }

  let memberGrantCount = try UserGroupMember
    .filter(remainingGroupIds.contains(UserGroupMember.Columns.groupId))
    .filter(UserGroupMember.Columns.userId == currentUserId)
    .fetchCount(db)
  if memberGrantCount > 0 {
    return true
  }

  return try UserGroup
    .filter(remainingGroupIds.contains(UserGroup.Columns.id))
    .filter(UserGroup.Columns.currentUserIsMember == true)
    .fetchCount(db) > 0
}

extension InlineProtocol.UpdateDeleteChat {
  func apply(_ db: Database) throws {
    Log.shared.debug("update delete chat \(peerID.toPeer())")

    let peer = peerID.toPeer()
    guard case let .thread(chatId) = peer else { return }

    try deleteLocalChatData(db, chatId: chatId)
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
    materializeMissingReferences: Bool,
    incrementUnreadCount: Bool = true
  ) throws {
    // Avoid double-applying side effects when the same message is replayed (eg. sync catch-up,
    // duplicate delivery, history prefill).
    let hadMessage = try Message
      .fetchOne(db, key: ["messageId": message.id, "chatId": message.chatID]) != nil

    let msg = try Message.save(
      db,
      protocolMessage: message,
      publishChanges: publishChanges,
      materializeMissingReferences: materializeMissingReferences
    )

    try Chat.updateLastMsgId(db, chatId: message.chatID, lastMsgId: msg.messageId, date: msg.date)

    // Increase unread count only when this message is newly inserted, not ours,
    // and newer than the dialog's read cursor. Catch-up applies dialog sidecars
    // before updates, and those sidecars already include server-computed unread
    // totals for delivered messages; applying this local delta too would double
    // count missed messages.
    if msg.out == false {
      let dialogBefore = try Dialog.get(peerId: msg.peerId).fetchOne(db)
      var didIncrement = false
      var reason = "not_newer_than_read_max"

      if !incrementUnreadCount {
        reason = "increment_disabled"
      } else if hadMessage {
        reason = "duplicate_message"
      } else if var dialog = dialogBefore {
        let readInboxMaxId = dialog.readInboxMaxId ?? 0
        if msg.messageId > readInboxMaxId {
          dialog.unreadCount = (dialog.unreadCount ?? 0) + 1
          try dialog.update(db)
          didIncrement = true
          reason = "incremented"
        }
      } else {
        reason = "missing_dialog"
      }

      let unreadBefore = dialogBefore.flatMap(\.unreadCount).map(String.init) ?? "nil"
      let readMax = dialogBefore.flatMap(\.readInboxMaxId).map(String.init) ?? "nil"
      Log.shared.info(
        "[UnreadDiag] incoming_message peer=\(msg.peerId) chatId=\(msg.chatId) msgId=\(msg.messageId) hadExisting=\(hadMessage) increment=\(didIncrement) reason=\(reason) unreadBefore=\(unreadBefore) readMax=\(readMax)"
      )
    }

    #if os(macOS)
    // Keep sync catch-up suppressed until its durable payload preserves every
    // notification-affecting input. The age gate also rejects delayed realtime delivery.
    if !suppressNotifications,
       !hadMessage,
       msg.out == false,
       MacNotifications.isFreshMessage(message, now: Date()),
       let currentUserID = Auth.shared.getCurrentUserId() {
      db.afterNextTransaction { committedDB in
        do {
          let replyToMessageID = message.hasReplyToMsgID ? message.replyToMsgID : nil
          guard let context = try MacIncomingNotificationContext.fetch(
            committedDB,
            peerID: msg.peerId,
            chatID: msg.chatId,
            replyToMessageID: replyToMessageID
          ) else { return }

          let dialogSelection = context.dialog.notificationSelection
          let isUnread = context.isUnread(messageID: msg.messageId)
          let isPersonallyAddressed = context.isPersonallyAddressed(
            message: message,
            currentUserID: currentUserID
          )

          Task { @MainActor in
            let effectiveMode = dialogSelection.resolveEffectiveMode(
              globalMode: INUserSettings.current.notification.mode
            )
            guard MacNotifications.shouldScheduleMessageNotification(
              for: message,
              effectiveMode: effectiveMode,
              source: .newMessage,
              deliveryState: .init(
                isNewlyInserted: true,
                isUnread: isUnread,
                isPersonallyAddressed: isPersonallyAddressed
              ),
              now: Date()
            ) else { return }
            Task.detached {
              await MacNotifications.shared.handleNewMessage(protocolMsg: message)
            }
          }
        } catch {
          Log.shared.error("Failed to resolve macOS notification context", error: error)
        }
      }
    }
    #endif
  }
}

extension InlineProtocol.UpdateNewMessageNotification {
  // Compatibility event for older Mac clients. New clients derive all local
  // notification work from the durable newMessage update.
  func apply(_: Database) throws {}
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

    let lastOnline: Date?
    if status.lastOnline.hasDate {
      lastOnline = User.lastOnlineDate(from: status.lastOnline.date)
      if lastOnline == nil {
        Log.scoped("UserPresence").error("Rejected invalid last-online Unix timestamp")
      }
    } else {
      lastOnline = nil
    }

    try User.filter(id: userID).updateAll(
      db,
      [
        Column("online").set(to: onlineBoolean),
        Column("lastOnline").set(to: lastOnline),
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
        .recordingVoice
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
      db.afterNextTransaction { _ in
        Task(priority: .userInitiated) { @MainActor in
          MessagesPublisher.shared.messagesDeleted(messageIds: messageIds, peer: peerID.toPeer())
        }
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
  @discardableResult
  func apply(_ db: Database) throws -> Bool {
    try apply(db, publishChanges: true)
  }

  @discardableResult
  func apply(
    _ db: Database,
    publishChanges: Bool,
    materializeMissingReferences: Bool = false
  ) throws -> Bool {
    let result = try Message.saveWithResult(
      db,
      protocolMessage: message,
      publishChanges: publishChanges,
      materializeMissingReferences: materializeMissingReferences
    )

    guard result.disposition.isAccepted else { return false }

    let translations = Translation
      .filter(Translation.Columns.messageId == message.id)
      .filter(Translation.Columns.chatId == message.chatID)
    if result.textOrEntitiesChanged {
      // The source text changed, so existing translations are no longer valid.
      try translations.deleteAll(db)
    } else if result.disposition == .newer {
      // A block/media-only edit may advance the message revision without
      // invalidating its translation. Keep revision-gated projections aligned.
      try translations.updateAll(
        db,
        Translation.Columns.msgRev.set(to: result.message.rev)
      )
    }

    // Message.saveWithResult owns the single post-commit publisher update.
    return true
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
    try Acknowledgement.save(db, cursors: self.chat.acknowledgements.cursors, chatId: chat.id, publishChanges: true)

    var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: chat.peerId.toPeer()))
      ?? Dialog(optimisticForChat: chat)
    dialog.chatId = chat.id
    dialog.spaceId = chat.spaceId
    Log.shared.debug("saving dialog \(dialog)")
    try dialog.save(db, onConflict: .replace)
    try DialogCatalogStore.include(dialogID: dialog.id, in: db)
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
    if member.userId == Auth.shared.getCurrentUserId() {
      try SpaceCatalogStore.include(spaceID: member.spaceId, in: db)
    }
  }
}

extension InlineProtocol.UpdateSpaceMemberDelete {
  func apply(_ db: Database) throws {
    Log.shared.debug("update space member delete user \(userID) from space \(spaceID)")

    try Member
      .filter(Column("userId") == userID)
      .filter(Column("spaceId") == spaceID)
      .deleteAll(db)

    guard userID == Auth.shared.getCurrentUserId() else { return }

    Log.shared.info("Current user was removed from space, cleaning up local data")
    let chatsInSpace = try Chat.filter(Column("spaceId") == spaceID).fetchAll(db)
    let chatIds = chatsInSpace.map(\.id)

    if !chatIds.isEmpty {
      try Dialog.filter(chatIds.contains(Column("chatId"))).deleteAll(db)
      try Dialog.filter(chatIds.contains(Column("peerThreadId"))).deleteAll(db)
      let chatBucketIds = chatIds.map { -$0 }
      try DbBucketState
        .filter(DbBucketState.Columns.bucketType == 1 && chatBucketIds.contains(DbBucketState.Columns.entityId))
        .deleteAll(db)
    }

    try Dialog.filter(Column("spaceId") == spaceID).deleteAll(db)
    try Chat.filter(Column("spaceId") == spaceID).deleteAll(db)
    try Member.filter(Column("spaceId") == spaceID).deleteAll(db)
    try DbBucketState
      .filter(DbBucketState.Columns.bucketType == 3 && DbBucketState.Columns.entityId == spaceID)
      .deleteAll(db)
    try Space.filter(Column("id") == spaceID).deleteAll(db)

    db.afterNextTransaction { _ in
      Task.detached {
        NotificationCenter.default.post(
          name: Notification.Name("spaceDeletedNotification"),
          object: nil,
          userInfo: ["spaceId": spaceID]
        )
      }
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
      try removePublicThreadsForSpace(spaceId: updatedMember.spaceId, db: db)
    }
  }

  private func removePublicThreadsForSpace(spaceId: Int64, db: Database) throws {
    let publicThreads = try Chat
      .filter(Chat.Columns.spaceId == spaceId)
      .filter(Chat.Columns.type == ChatType.thread.rawValue)
      .filter(Chat.Columns.isPublic == true)
      .fetchAll(db)

    let chatIds = publicThreads.map(\.id)
    guard !chatIds.isEmpty else { return }

    try Message.filter(chatIds.contains(Column("chatId"))).deleteAll(db)
    try Dialog.filter(chatIds.contains(Column("chatId"))).deleteAll(db)
    try Dialog.filter(chatIds.contains(Column("peerThreadId"))).deleteAll(db)
    let chatBucketIds = chatIds.map { -$0 }
    try DbBucketState
      .filter(DbBucketState.Columns.bucketType == 1 && chatBucketIds.contains(DbBucketState.Columns.entityId))
      .deleteAll(db)
    try Chat.filter(chatIds.contains(Column("id"))).deleteAll(db)
  }
}

extension InlineProtocol.UpdateJoinSpace {
  func apply(_ db: Database) throws {
    try saveMissingSidecarSpace(space, db: db, allowBehindRetainedCursor: true)
    // The User journal embeds the membership at join time. Its role/access may
    // already have advanced through the independent Space journal. Preserve an
    // existing row, but a sequenced access gain must restore a missing one even
    // when the retained Space cursor is ahead of this historical payload.
    let member = Member(from: member)
    guard try Member
      .filter(Member.Columns.userId == member.userId)
      .filter(Member.Columns.spaceId == member.spaceId)
      .fetchOne(db) == nil
    else { return }
    try member.save(db)
  }
}

extension InlineProtocol.UpdateChatParticipantAdd {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat participant add \(chatID) \(participant.userID)")

    try ChatParticipant.save(db, from: participant, chatId: chatID)
  }
}

extension InlineProtocol.UpdateChatParticipantDelete {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat participant delete \(chatID) \(userID)")

    try ChatParticipant.filter(Column("chatId") == chatID).filter(Column("userId") == userID).deleteAll(db)

    if userID == Auth.shared.getCurrentUserId() {
      try deleteLocalPrivateThreadIfCurrentUserLostAccess(db, chatId: chatID)
    }
  }
}

extension InlineProtocol.UpdateChatParticipantGroupAdd {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat participant group add \(chatID) \(groupParticipant.groupID)")

    guard hasGroupParticipant else { return }
    try ChatParticipantGroup.save(db, from: groupParticipant, chatId: chatID)
  }
}

extension InlineProtocol.UpdateChatParticipantGroupDelete {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat participant group delete \(chatID) \(groupID)")

    try ChatParticipantGroup
      .filter(ChatParticipantGroup.Columns.chatId == chatID)
      .filter(ChatParticipantGroup.Columns.groupId == groupID)
      .deleteAll(db)

    try deleteLocalPrivateThreadIfCurrentUserLostAccess(db, chatId: chatID)
  }
}

extension InlineProtocol.UpdateUserAddedToChat {
  func apply(_ db: Database) throws {
    guard chatID > 0 else { return }
    if hasParticipant {
      try ChatParticipant.save(db, from: participant, chatId: chatID)
    }
    if hasGroup {
      try ChatParticipantGroup.save(db, from: group, chatId: chatID)
    }
  }
}

extension InlineProtocol.UpdateUserRemovedFromChat {
  func apply(_ db: Database) throws {
    guard chatID > 0 else { return }
    try deleteLocalChatData(db, chatId: chatID)
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
      if hasAgentContext {
        chat.agentContext = Chat.serializedAgentContext(agentContext)
      }
      try chat.save(db)
    }
  }
}

extension InlineProtocol.UpdateChatPermissions {
  func apply(_ db: Database) throws {
    try Chat
      .filter(Chat.Columns.id == chatID)
      .updateAll(
        db,
        Chat.Columns.canUpdateInfo.set(to: hasPermissions ? permissions.canUpdateInfo : nil)
      )
  }
}

extension InlineProtocol.UpdateChatMoved {
  func apply(_ db: Database) throws {
    var updatedChat = Chat(from: chat)
    try updatedChat.saveWithValidLastMsg(db)
    try Acknowledgement.save(db, cursors: chat.acknowledgements.cursors, chatId: updatedChat.id, publishChanges: true)

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
    let receivingUserID = Auth.shared.getCurrentUserId()

    Task { @MainActor in
      apply(receivingUserID: receivingUserID)
    }
  }

  @MainActor
  func apply(receivingUserID: Int64?) {
    guard hasSettings, let receivingUserID else { return }
    INUserSettings.current.updateFromServer(settings, receivingUserID: receivingUserID)
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

extension InlineProtocol.UpdateDialogCollapsedMaxId {
  func apply(_ db: Database) throws {
    Log.shared.debug("update dialog collapsed max id for peer \(peerID.toPeer())")

    if var dialog = try Dialog.get(peerId: peerID.toPeer()).fetchOne(db) {
      dialog.collapsedMaxId = hasMaxID ? maxID : nil
      try dialog.update(db)
    } else {
      Log.shared.warning("Could not find dialog for peer \(peerID.toPeer()) to update collapsed max id")
    }
  }
}

extension InlineProtocol.UpdateChatOpen {
  @discardableResult
  func apply(_ db: Database) throws -> Bool {
    guard isValidChatOpenEnvelope(self) else { return false }
    Log.shared.debug("update chat open for chat \(chat.id)")

    if hasUser {
      _ = try User.save(db, user: user)
    }

    for preparedChat in try preparedSidecarChats([chat], db: db) {
      try saveMissingSidecarChat(
        chat,
        preparedChat: preparedChat,
        db: db,
        allowBehindRetainedCursor: true
      )
    }
    try Acknowledgement.save(db, cursors: chat.acknowledgements.cursors, chatId: chat.id, publishChanges: true)
    _ = try dialog.saveFull(db)
    try DialogCatalogStore.include(
      dialogID: Dialog.getDialogId(peerId: dialog.peer.toPeer()),
      in: db
    )
    return true
  }
}

extension InlineProtocol.UpdateDialogFolder {
  func apply(_ db: Database) throws {
    switch folderChange {
    case let .folder(folder):
      try folder.saveFull(db)
      for dialog in dialogs {
        try dialog.saveFull(db)
        try DialogCatalogStore.include(
          dialogID: Dialog.getDialogId(peerId: dialog.peer.toPeer()),
          in: db
        )
      }
    case let .deletedFolderID(folderID):
      for dialog in dialogs {
        try dialog.saveFull(db)
        try DialogCatalogStore.include(
          dialogID: Dialog.getDialogId(peerId: dialog.peer.toPeer()),
          in: db
        )
      }
      try DialogFolder.deleteOne(db, key: folderID)
    case .none:
      // Membership-only moves still carry complete changed dialogs.
      for dialog in dialogs {
        try dialog.saveFull(db)
        try DialogCatalogStore.include(
          dialogID: Dialog.getDialogId(peerId: dialog.peer.toPeer()),
          in: db
        )
      }
    }
  }
}

extension InlineProtocol.UpdateReadMaxId {
  func apply(_ db: Database) throws {
    Log.shared.debug(
      "update read max id for peer \(peerID.toPeer()) readMaxId: \(readMaxID) unreadCount: \(unreadCount)"
    )

    if var dialog = try Dialog.get(peerId: peerID.toPeer()).fetchOne(db) {
      let currentReadMaxID = max(0, dialog.readInboxMaxId ?? 0)
      guard readMaxID > currentReadMaxID else {
        // Direct transaction results and sequenced User-bucket replay can
        // deliver the same read projection through different paths. Treat an
        // equal marker as already applied so it cannot erase a later explicit
        // mark-unread; reject a lower marker so neither frontier nor count can
        // regress.
        Log.shared.debug(
          "Ignored non-advancing read max id for peer \(peerID.toPeer()) current: \(currentReadMaxID) incoming: \(readMaxID)"
        )
        return
      }
      dialog.readInboxMaxId = readMaxID
      dialog.unreadCount = Int(unreadCount)
      dialog.unreadMark = false
      try dialog.update(db)
    } else {
      Log.shared.warning("Could not find dialog for peer \(peerID.toPeer()) to update read state")
    }
  }
}
