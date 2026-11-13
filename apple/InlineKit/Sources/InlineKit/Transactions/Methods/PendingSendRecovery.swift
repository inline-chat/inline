import Auth
import Foundation
import GRDB
import Logger

/// Resumes outgoing sends that a terminated process left in `.sending`.
///
/// The legacy `Transactions` queue holds media sends in memory only, so a kill
/// mid-upload used to leave the row spinning forever with no retry. Message rows
/// are the outbox (Telegram's model): on launch, recent rows are re-admitted with
/// their original random id, so the upload resumes from the parts the server
/// already holds and the server's per-sender random-id dedupe keeps the final send
/// idempotent. Older rows become `.failed`, which restores the Retry action.
@MainActor
public enum PendingSendRecovery {
  /// Sends younger than this resume automatically; older ones need an explicit retry.
  static let automaticResumeWindow: TimeInterval = 24 * 60 * 60

  private static let log = Log.scoped("PendingSendRecovery")
  private static var didRun = false

  struct Plan: Equatable {
    var resume: [Int64] = []
    var fail: [Int64] = []
  }

  /// Pure selection so the policy is testable without a running queue.
  static func plan(for messages: [Message], now: Date, window: TimeInterval = automaticResumeWindow) -> Plan {
    var plan = Plan()
    for message in messages.sorted(by: { $0.date < $1.date }) {
      let isRecoverable = message.randomId != nil
        && !(message.transactionId ?? "").isEmpty
        && now.timeIntervalSince(message.date) <= window
      if isRecoverable {
        plan.resume.append(message.messageId)
      } else {
        plan.fail.append(message.messageId)
      }
    }
    return plan
  }

  /// Runs once per process, in the main app only.
  public static func recoverAfterLaunch(
    database: AppDatabase = .shared,
    auth: AuthHandle = Auth.shared.handle,
    transactions: Transactions = .shared,
    now: Date = Date()
  ) async {
    guard !didRun, !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
    didRun = true
    guard let account = try? auth.beginAccountMutation() else { return }

    let pending: [FullMessage]
    do {
      pending = try await database.dbWriter.read { db in
        try auth.validateAccountMutation(account)
        return try FullMessage.queryRequest(currentUserId: account.userID)
          .filter(Column("out") == true)
          .filter(Column("fromId") == account.userID)
          .filter(Column("status") == MessageSendingStatus.sending.rawValue)
          .filter(Column("messageId") < 0)
          // Only the legacy queue stamps transactionId; RealtimeV2 sends persist themselves.
          .filter(Column("transactionId") != nil && Column("transactionId") != "")
          .fetchAll(db)
      }
    } catch {
      log.error("Failed to load interrupted sends", error: error)
      return
    }
    // Sends admitted by this process (for example while offline before the first
    // connection) are live in the queue; only orphans from a terminated process recover.
    let orphaned = pending.filter { candidate in
      guard let transactionId = candidate.message.transactionId else { return false }
      return !transactions.wasAdmittedInThisProcess(transactionId: transactionId)
    }
    guard !orphaned.isEmpty else { return }

    let byId = Dictionary(orphaned.map { ($0.message.messageId, $0) }, uniquingKeysWith: { first, _ in first })
    let plan = plan(for: orphaned.map(\.message), now: now)
    var failed = plan.fail
    var resumed = 0

    for messageId in plan.resume {
      guard let fullMessage = byId[messageId],
            let mediaItems = recoverableMedia(for: fullMessage),
            let transaction = TransactionSendMessage(
              recovering: fullMessage.message,
              mediaItems: mediaItems
            )
      else {
        failed.append(messageId)
        continue
      }
      // A rejected admission (logout or reset in progress) leaves the row for the next launch.
      guard (try? auth.validateAccountMutation(account)) != nil,
            transactions.resumeRecovered(transaction: .sendMessage(transaction))
      else { continue }
      resumed += 1
    }

    if !failed.isEmpty {
      await markFailed(failed, in: orphaned, database: database, auth: auth, account: account)
    }
    log.info("Recovered interrupted sends resumed=\(resumed) failed=\(failed.count)")
  }

  /// The row's media, or nil when it references media whose local rows are gone; such a
  /// send must fail rather than go out as a caption-only message.
  static func recoverableMedia(for fullMessage: FullMessage) -> [FileMediaItem]? {
    let items = FailedMessageResender.mediaItems(for: fullMessage)
    let message = fullMessage.message
    let referencesMedia = message.photoId != nil || message.videoId != nil
      || message.documentId != nil || message.voiceContent != nil
    return referencesMedia && items.isEmpty ? nil : items
  }

  private static func markFailed(
    _ messageIds: [Int64],
    in pending: [FullMessage],
    database: AppDatabase,
    auth: AuthHandle,
    account: AuthAccountMutationToken
  ) async {
    let targets = pending.map(\.message).filter { messageIds.contains($0.messageId) }
    do {
      let updated = try await database.dbWriter.write { db -> [Message] in
        try auth.validateAccountMutation(account)
        var updated: [Message] = []
        for message in targets {
          try Message
            .filter(Column("messageId") == message.messageId && Column("chatId") == message.chatId)
            .filter(Column("status") == MessageSendingStatus.sending.rawValue)
            .updateAll(db, Column("status").set(to: MessageSendingStatus.failed.rawValue))
          if let stored = try Message.fetchOne(db, key: ["messageId": message.messageId, "chatId": message.chatId]) {
            updated.append(stored)
          }
        }
        return updated
      }
      for message in updated {
        MessagesPublisher.shared.messageUpdatedSync(message: message, peer: message.peerId, animated: false)
      }
    } catch {
      log.error("Failed to mark interrupted sends as failed", error: error)
    }
  }
}
