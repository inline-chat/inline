import Auth
import Foundation
import GRDB
import Logger
import RealtimeV2

#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct AutomaticReadDemand: Sendable, Equatable {
  let maxID: Int64
  let highestVisibleIncomingID: Int64
  let unreadMark: Bool
}

struct AutomaticReadCoalescingState: Sendable, Equatable {
  private(set) var inFlight: AutomaticReadDemand?
  private(set) var pending: AutomaticReadDemand?
  var inFlightMaxID: Int64? { inFlight?.maxID }
  var pendingMaxID: Int64? { pending?.maxID }
  private(set) var highestSuccessfulMaxID: Int64 = 0
  private(set) var lastAttemptedMaxID: Int64 = 0

  mutating func enqueue(
    _ maxID: Int64,
    highestVisibleIncomingID: Int64? = nil,
    unreadMark: Bool = false
  ) -> Int64? {
    guard maxID > 0 else { return nil }
    let demand = AutomaticReadDemand(
      maxID: maxID,
      highestVisibleIncomingID: highestVisibleIncomingID ?? maxID,
      unreadMark: unreadMark
    )
    if inFlightMaxID == nil {
      // A failed concrete marker may be retried, but a later visibility pass
      // must never regress below a marker that may already have committed.
      guard maxID > highestSuccessfulMaxID, maxID >= lastAttemptedMaxID else { return nil }
      lastAttemptedMaxID = maxID
      inFlight = demand
      return maxID
    }

    let queuedHighWatermark = max(inFlightMaxID ?? 0, pendingMaxID ?? 0)
    guard maxID > queuedHighWatermark else { return nil }
    pending = demand
    return nil
  }

  mutating func succeed(_ sentMaxID: Int64) -> Int64? {
    guard inFlightMaxID == sentMaxID else { return nil }
    inFlight = nil
    highestSuccessfulMaxID = max(highestSuccessfulMaxID, sentMaxID)

    guard let pending else { return nil }
    self.pending = nil
    guard pending.maxID > highestSuccessfulMaxID else { return nil }
    lastAttemptedMaxID = pending.maxID
    inFlight = pending
    return pending.maxID
  }

  mutating func retryTarget(afterFailureOf sentMaxID: Int64) -> Int64? {
    guard inFlightMaxID == sentMaxID else { return nil }
    guard let pending else { return sentMaxID }
    self.pending = nil
    lastAttemptedMaxID = pending.maxID
    inFlight = pending
    return pending.maxID
  }

  func owns(_ maxID: Int64) -> Bool {
    inFlightMaxID == maxID
  }
}

struct AutomaticReadAdmission: Sendable, Equatable {
  let currentReadMaxID: Int64
  let certifiedMaxID: Int64
  let unreadMark: Bool

  init(currentReadMaxID: Int64, certifiedMaxID: Int64, unreadMark: Bool = false) {
    self.currentReadMaxID = currentReadMaxID
    self.certifiedMaxID = certifiedMaxID
    self.unreadMark = unreadMark
  }

  static func resolve(
    _ db: Database,
    peerId: Peer,
    chatId: Int64,
    highestVisibleIncomingID: Int64
  ) throws -> AutomaticReadAdmission? {
    guard 1 ... MessageHistoryHole.positiveMessageIDMax ~= highestVisibleIncomingID,
          let dialog = try Dialog.get(peerId: peerId).fetchOne(db),
          let candidate = try Message
            .filter(Message.Columns.chatId == chatId)
            .filter(Message.Columns.messageId == highestVisibleIncomingID)
            .fetchOne(db),
          Self.matches(candidate: candidate, peerId: peerId),
          candidate.out != true,
          !candidate.isServiceMessage
    else { return nil }

    let currentReadMaxID = max(0, dialog.readInboxMaxId ?? 0)
    let persistedCoverage = MessageHistoryCoverageProjection(
      messages: [],
      holes: try MessageHistoryCoverageStore.holes(db, chatId: chatId),
      olderCandidateMessageID: nil,
      newerCandidateMessageID: nil
    )
    guard let certifiedMaxID = persistedCoverage.certifiedReadMaxID(
      after: currentReadMaxID,
      through: highestVisibleIncomingID
    ) else { return nil }

    return AutomaticReadAdmission(
      currentReadMaxID: currentReadMaxID,
      certifiedMaxID: certifiedMaxID,
      unreadMark: dialog.unreadMark == true
    )
  }

  /// Re-check a retained demand immediately before sending it. Coverage may
  /// have been invalidated by repair, or an explicit unread intent may have
  /// superseded the visibility event while the retry slept.
  static func stillAdmits(
    _ db: Database,
    peerId: Peer,
    chatId: Int64,
    demand: AutomaticReadDemand
  ) throws -> Bool {
    guard let admission = try resolve(
      db,
      peerId: peerId,
      chatId: chatId,
      highestVisibleIncomingID: demand.highestVisibleIncomingID
    ) else { return false }
    return admission.certifiedMaxID >= demand.maxID
      && admission.unreadMark == demand.unreadMark
  }

  private static func matches(candidate: Message, peerId: Peer) -> Bool {
    switch peerId {
    case let .user(id):
      candidate.peerUserId == id
    case let .thread(id):
      candidate.peerThreadId == id
    }
  }
}

enum AutomaticReadRetryPolicy {
  static let baseDelaySeconds = 0.5
  static let maximumDelaySeconds = 8.0

  static func delaySeconds(failureCount: Int, jitterUnit: Double) -> Double {
    let exponent = min(max(0, failureCount - 1), 4)
    let exponentialDelay = baseDelaySeconds * pow(2, Double(exponent))
    let boundedJitterUnit = min(1, max(0, jitterUnit))
    let jitterMultiplier = 0.8 + (0.4 * boundedJitterUnit)
    return min(maximumDelaySeconds, exponentialDelay * jitterMultiplier)
  }

  static func shouldRetry(_ error: any Error) -> Bool {
    guard let transactionError = error as? TransactionError2 else { return true }
    return switch transactionError {
    case .timeout, .persistenceFailed, .commitOutcomeUnknownAfterReconnect, .rejectedBeforeExecution:
      true
    case let .rpcError(error):
      error.errorCode == .rateLimit
        || error.errorCode == .internalError
        || error.errorCode == .unknown
        || error.code == 429
        || error.code >= 500
    case .invalid, .dependencyFailed:
      false
    }
  }
}

private enum ReadSendResult {
  case applied(authoritativeMaxID: Int64?)
  case retryableFailure
  case permanentFailure
}

public final class UnreadManager: Sendable {
  public static let shared = UnreadManager()

  private let log = Log.scoped("UnreadManager", enableTracing: false)
  private static let readAllLocalCooldown: TimeInterval = 0.15
  private static let readAllRemoteCooldown: TimeInterval = 0.35

  private actor ReadAllGate {
    struct State {
      var lastLocalWriteAt: TimeInterval = 0
      var lastRemoteSendAt: TimeInterval = 0
      var remoteInFlight = false
    }

    private var owner: AuthAccountMutationToken?
    private var stateByDialogId: [Int64: State] = [:]

    func begin(
      owner expectedOwner: AuthAccountMutationToken,
      dialogId: Int64,
      now: TimeInterval,
      localCooldown: TimeInterval,
      remoteCooldown: TimeInterval
    ) throws -> (shouldWriteLocal: Bool, shouldSendRemote: Bool) {
      try Auth.shared.handle.validateAccountMutation(expectedOwner)
      if owner != expectedOwner {
        owner = expectedOwner
        stateByDialogId.removeAll(keepingCapacity: true)
      }
      var state = stateByDialogId[dialogId] ?? State()

      let shouldWriteLocal = now - state.lastLocalWriteAt >= localCooldown
      if shouldWriteLocal {
        state.lastLocalWriteAt = now
      }

      let shouldSendRemote = state.remoteInFlight == false && now - state.lastRemoteSendAt >= remoteCooldown
      if shouldSendRemote {
        state.lastRemoteSendAt = now
        state.remoteInFlight = true
      }

      stateByDialogId[dialogId] = state
      return (shouldWriteLocal, shouldSendRemote)
    }

    func completeRemote(owner expectedOwner: AuthAccountMutationToken, dialogId: Int64) {
      guard owner == expectedOwner, var state = stateByDialogId[dialogId] else { return }
      state.remoteInFlight = false
      stateByDialogId[dialogId] = state
    }
  }

  actor VisibleReadGate {
    struct Entry {
      let leaseID = UUID()
      var state = AutomaticReadCoalescingState()
      var task: Task<Void, Never>?
      var cancelledAt: ContinuousClock.Instant?
    }

    private var owner: AuthAccountMutationToken?
    private var stateByDialogId: [Int64: Entry] = [:]
    private let auth: AuthHandle

    init(auth: AuthHandle = Auth.shared.handle) {
      self.auth = auth
    }

    @discardableResult
    func enqueue(
      owner expectedOwner: AuthAccountMutationToken,
      dialogId: Int64,
      admission: AutomaticReadAdmission,
      highestVisibleIncomingID: Int64,
      requestedAt: ContinuousClock.Instant,
      drain: @escaping @Sendable (UUID, Int64) async -> Void
    ) throws -> Bool {
      try auth.validateAccountMutation(expectedOwner)
      resetIfNeeded(for: expectedOwner)
      var entry = stateByDialogId[dialogId] ?? Entry()
      if let cancelledAt = entry.cancelledAt, requestedAt <= cancelledAt { return false }
      let next = entry.state.enqueue(
        admission.certifiedMaxID,
        highestVisibleIncomingID: highestVisibleIncomingID,
        unreadMark: admission.unreadMark
      )
      if let next {
        let leaseID = entry.leaseID
        entry.task = Task { await drain(leaseID, next) }
      }
      stateByDialogId[dialogId] = entry
      return next != nil
    }

    func succeed(
      owner expectedOwner: AuthAccountMutationToken,
      dialogId: Int64,
      leaseID: UUID,
      sentMaxID: Int64
    ) throws -> Int64? {
      try auth.validateAccountMutation(expectedOwner)
      guard owner == expectedOwner, var entry = stateByDialogId[dialogId], entry.leaseID == leaseID else {
        return nil
      }
      let next = entry.state.succeed(sentMaxID)
      if next == nil { entry.task = nil }
      stateByDialogId[dialogId] = entry
      return next
    }

    func retryTarget(
      owner expectedOwner: AuthAccountMutationToken,
      dialogId: Int64,
      leaseID: UUID,
      failedMaxID: Int64
    ) -> Int64? {
      guard (try? auth.validateAccountMutation(expectedOwner)) != nil,
            owner == expectedOwner,
            var entry = stateByDialogId[dialogId],
            entry.leaseID == leaseID
      else { return nil }
      let next = entry.state.retryTarget(afterFailureOf: failedMaxID)
      stateByDialogId[dialogId] = entry
      return next
    }

    func currentDemand(
      owner expectedOwner: AuthAccountMutationToken,
      dialogId: Int64,
      leaseID: UUID,
      maxID: Int64
    ) -> AutomaticReadDemand? {
      guard (try? auth.validateAccountMutation(expectedOwner)) != nil,
            owner == expectedOwner,
            let entry = stateByDialogId[dialogId],
            entry.leaseID == leaseID,
            entry.state.owns(maxID)
      else { return nil }
      return entry.state.inFlight
    }

    func abandon(owner expectedOwner: AuthAccountMutationToken, dialogId: Int64, leaseID: UUID) {
      guard owner == expectedOwner, stateByDialogId[dialogId]?.leaseID == leaseID else { return }
      let previous = stateByDialogId[dialogId]
      previous?.task?.cancel()
      stateByDialogId[dialogId] = previous?.cancelledAt.map { Entry(cancelledAt: $0) }
    }

    func cancel(
      owner expectedOwner: AuthAccountMutationToken,
      dialogId: Int64,
      at cancelledAt: ContinuousClock.Instant
    ) throws {
      try auth.validateAccountMutation(expectedOwner)
      resetIfNeeded(for: expectedOwner)
      stateByDialogId[dialogId]?.task?.cancel()
      // Keep the event boundary so an older visibility task still awaiting
      // its database admission cannot create a fresh lease after cancellation.
      let boundary = stateByDialogId[dialogId]?.cancelledAt.map { max($0, cancelledAt) } ?? cancelledAt
      stateByDialogId[dialogId] = Entry(cancelledAt: boundary)
    }

    private func resetIfNeeded(for expectedOwner: AuthAccountMutationToken) {
      guard owner != expectedOwner else { return }
      for entry in stateByDialogId.values { entry.task?.cancel() }
      owner = expectedOwner
      stateByDialogId.removeAll(keepingCapacity: true)
    }
  }

  private let readAllGate = ReadAllGate()
  private let visibleReadGate = VisibleReadGate()

  private init() {}

  private let db = AppDatabase.shared

  @discardableResult
  private func sendReadMessagesToServer(
    peerId: Peer,
    maxId: Int64?,
    expectedAccount: AuthAccountMutationToken
  ) async -> ReadSendResult {
    do {
      let rpcResult = try await Api.realtime.send(
        .readMessages(peerId: peerId, maxId: maxId),
        expectedAccount: expectedAccount
      )
      let authoritativeMaxID: Int64?
      if case let .readMessages(result) = rpcResult {
        authoritativeMaxID = result.updates.compactMap { update -> Int64? in
          guard case let .updateReadMaxID(read) = update.update,
                read.peerID.toPeer() == peerId else { return nil }
          return read.readMaxID
        }.max()
      } else {
        authoritativeMaxID = nil
      }
      return .applied(authoritativeMaxID: authoritativeMaxID)
    } catch is CancellationError {
      return .retryableFailure
    } catch {
      log.error("Realtime readMessages failed", error: error)
      return AutomaticReadRetryPolicy.shouldRetry(error) ? .retryableFailure : .permanentFailure
    }
  }

  // This is called when chat opens initially
  public func readMessages(_ maxId: Int64, in peerId: Peer, chatId: Int64) {
    readVisible(peerId: peerId, chatId: chatId, highestVisibleIncomingID: maxId)
  }

  /// Advances automatic read state only through visible incoming history whose
  /// continuity is certified by persisted history state.
  ///
  /// The local dialog is deliberately not changed here. The authoritative
  /// `UpdateReadMaxId` returned by the server owns `readInboxMaxId`, unread
  /// count, and unread-mark projection.
  public func readVisible(
    peerId: Peer,
    chatId: Int64,
    highestVisibleIncomingID: Int64
  ) {
    let requestedAt = ContinuousClock.now
    guard highestVisibleIncomingID > 0,
          let mutationToken = try? Auth.shared.handle.beginAccountMutation()
    else { return }

    let dialogId = Dialog.getDialogId(peerId: peerId)
    Task(priority: .userInitiated) {
      do {
        let admission = try await db.dbWriter.write { db -> AutomaticReadAdmission? in
          try Auth.shared.handle.validateAccountMutation(mutationToken)
          return try AutomaticReadAdmission.resolve(
            db,
            peerId: peerId,
            chatId: chatId,
            highestVisibleIncomingID: highestVisibleIncomingID
          )
        }
        guard let admission else { return }
        try await visibleReadGate.enqueue(
          owner: mutationToken,
          dialogId: dialogId,
          admission: admission,
          highestVisibleIncomingID: highestVisibleIncomingID,
          requestedAt: requestedAt
        ) { [self] leaseID, maxID in
          await drainVisibleReads(
            owner: mutationToken,
            peerId: peerId,
            chatId: chatId,
            dialogId: dialogId,
            leaseID: leaseID,
            firstMaxID: maxID
          )
        }
      } catch is CancellationError {
        return
      } catch {
        log.error("Failed to resolve automatic read frontier", error: error)
      }
    }
  }

  /// An explicit unread intent supersedes any retained visibility event. The
  /// per-peer transaction lane orders an already-sent read before this intent;
  /// cancelling its lease prevents a later retry from undoing it.
  func cancelAutomaticReads(in peerId: Peer) async {
    let cancelledAt = ContinuousClock.now
    guard let owner = try? Auth.shared.handle.beginAccountMutation() else { return }
    try? await visibleReadGate.cancel(
      owner: owner, dialogId: Dialog.getDialogId(peerId: peerId), at: cancelledAt
    )
  }

  private func drainVisibleReads(
    owner: AuthAccountMutationToken,
    peerId: Peer,
    chatId: Int64,
    dialogId: Int64,
    leaseID: UUID,
    firstMaxID: Int64
  ) async {
    var nextMaxID: Int64? = firstMaxID
    var failureCount = 0
    while let maxID = nextMaxID {
      guard let demand = await visibleReadGate.currentDemand(
        owner: owner,
        dialogId: dialogId,
        leaseID: leaseID,
        maxID: maxID
      ) else { return }

      let result: ReadSendResult
      do {
        let admission = try await db.dbWriter.write { db in
          try Auth.shared.handle.validateAccountMutation(owner)
          let currentMaxID = try Dialog.get(peerId: peerId).fetchOne(db)?.readInboxMaxId ?? 0
          return (
            alreadyApplied: currentMaxID >= maxID,
            maySend: try AutomaticReadAdmission.stillAdmits(db, peerId: peerId, chatId: chatId, demand: demand)
          )
        }
        if admission.alreadyApplied {
          result = .applied(authoritativeMaxID: maxID)
        } else if admission.maySend {
          guard await visibleReadGate.currentDemand(
            owner: owner, dialogId: dialogId, leaseID: leaseID, maxID: maxID
          ) != nil else { return }
          result = await sendReadMessagesToServer(peerId: peerId, maxId: maxID, expectedAccount: owner)
        } else {
          await visibleReadGate.abandon(owner: owner, dialogId: dialogId, leaseID: leaseID)
          return
        }
      } catch {
        result = .retryableFailure
      }

      var shouldRetry = false
      switch result {
      case let .applied(authoritativeMaxID):
        do {
          try Auth.shared.handle.validateAccountMutation(owner)
          let requiredMaxID = min(maxID, authoritativeMaxID ?? maxID)
          let durableMaxID = try await db.dbWriter.write { db in
            try Auth.shared.handle.validateAccountMutation(owner)
            return try Dialog.get(peerId: peerId).fetchOne(db)?.readInboxMaxId ?? 0
          }
          guard await visibleReadGate.currentDemand(
            owner: owner, dialogId: dialogId, leaseID: leaseID, maxID: maxID
          ) != nil else { return }
          guard durableMaxID >= requiredMaxID else {
            // The response may be buffered behind user-bucket catch-up. Keep
            // ownership until its projection actually commits.
            shouldRetry = true
            break
          }
          if requiredMaxID < maxID {
            // A definitive server clamp retires this stale demand; never spin
            // forever waiting for a marker the server did not acknowledge.
            await visibleReadGate.abandon(owner: owner, dialogId: dialogId, leaseID: leaseID)
            nextMaxID = nil
          } else {
            nextMaxID = try await visibleReadGate.succeed(
              owner: owner,
              dialogId: dialogId,
              leaseID: leaseID,
              sentMaxID: maxID
            )
          }
          NotificationCleanup.removeNotifications(
            threadId: "chat_\(chatId)",
            upToMessageId: requiredMaxID,
            expectedAccount: owner
          )
          failureCount = 0
        } catch {
          shouldRetry = true
        }

      case .retryableFailure:
        shouldRetry = true

      case .permanentFailure:
        await visibleReadGate.abandon(owner: owner, dialogId: dialogId, leaseID: leaseID)
        return
      }

      if shouldRetry {
        failureCount += 1
        guard let retryMaxID = await visibleReadGate.retryTarget(
          owner: owner,
          dialogId: dialogId,
          leaseID: leaseID,
          failedMaxID: maxID
        ) else {
          await visibleReadGate.abandon(owner: owner, dialogId: dialogId, leaseID: leaseID)
          return
        }
        nextMaxID = retryMaxID
        let delaySeconds = AutomaticReadRetryPolicy.delaySeconds(
          failureCount: failureCount,
          jitterUnit: Double.random(in: 0 ... 1)
        )
        do {
          try await Task.sleep(for: .seconds(delaySeconds))
        } catch {
          await visibleReadGate.abandon(owner: owner, dialogId: dialogId, leaseID: leaseID)
          return
        }
      }
    }
  }

  // Useful in context menu to mark all messages as read
  public func readAll(_ peerId: Peer, chatId: Int64) {
    log.trace("readAll")
    guard let mutationToken = try? Auth.shared.handle.beginAccountMutation() else { return }
    let localDialogId = Dialog.getDialogId(peerId: peerId)

    Task(priority: .userInitiated) {
      let now = Date().timeIntervalSinceReferenceDate
      let gateDecision: (shouldWriteLocal: Bool, shouldSendRemote: Bool)
      do {
        gateDecision = try await readAllGate.begin(
          owner: mutationToken,
          dialogId: localDialogId,
          now: now,
          localCooldown: Self.readAllLocalCooldown,
          remoteCooldown: Self.readAllRemoteCooldown
        )
      } catch {
        return
      }
      let (shouldWriteLocal, shouldSendRemote) = gateDecision

      if shouldWriteLocal {
        do {
          try await db.dbWriter.write { db in
            try Auth.shared.handle.validateAccountMutation(mutationToken)
            let before = try Dialog.fetchOne(db, id: localDialogId)
            let hasUnread = (Column("unreadCount") > 0) || (Column("unreadMark") == true)
            try Dialog
              .filter(id: localDialogId)
              .filter(hasUnread)
              .updateAll(db, [
                Column("unreadCount").set(to: 0),
                Column("unreadMark").set(to: false)
              ])
            let after = try Dialog.fetchOne(db, id: localDialogId)
            let beforeUnread = before?.unreadCount ?? 0
            let afterUnread = after?.unreadCount ?? 0
            if beforeUnread != afterUnread || before?.unreadMark != after?.unreadMark {
              let beforeMark = before?.unreadMark.map(String.init) ?? "nil"
              let afterMark = after?.unreadMark.map(String.init) ?? "nil"
              log.info(
                "[UnreadDiag] read_all_local peer=\(peerId) chatId=\(chatId) dialogId=\(localDialogId) unread=\(beforeUnread)->\(afterUnread) mark=\(beforeMark)->\(afterMark) remote=\(shouldSendRemote)"
              )
            }
          }
        } catch {
          log.error("Failed to update local DB with unread count", error: error)
        }

        #if os(macOS)
        // Message-list visibility can request read-all repeatedly. Reuse the
        // existing local-write gate so notification-center enumeration is bounded.
        NotificationCleanup.removeNotifications(
          threadId: "chat_\(chatId)",
          upToMessageId: nil,
          expectedAccount: mutationToken
        )
        #endif
      }

      if shouldSendRemote {
        if (try? Auth.shared.handle.validateAccountMutation(mutationToken)) != nil {
          await sendReadMessagesToServer(
            peerId: peerId,
            maxId: nil,
            expectedAccount: mutationToken
          )
        }
        await readAllGate.completeRemote(owner: mutationToken, dialogId: localDialogId)
      }
    }

    #if os(iOS)
    NotificationCleanup.removeNotifications(
      threadId: "chat_\(chatId)",
      upToMessageId: nil,
      expectedAccount: mutationToken
    )
    #endif
  }
}
