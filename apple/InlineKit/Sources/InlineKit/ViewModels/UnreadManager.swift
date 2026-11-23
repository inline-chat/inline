import Auth
import Foundation
import GRDB
import Logger
import RealtimeV2
import Synchronization

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A read of what was on screen. Like Telegram, everything others sent that is visible is read,
/// service rows included, and a read may cross history this device has not loaded. The count can
/// only drop by the messages stored here, so a read across such a gap asks the server for the
/// chat's count once it is pushed (Telegram's push-then-validate).
struct AutomaticReadAdmission: Sendable, Equatable {
  let maxID: Int64
  /// The range read has history not stored here.
  let crossesGap: Bool

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
          candidate.out != true
    else { return nil }

    let currentReadMaxID = max(0, dialog.readInboxMaxId ?? 0)
    guard highestVisibleIncomingID > currentReadMaxID else { return nil }
    let persistedCoverage = MessageHistoryCoverageProjection(
      messages: [],
      holes: try MessageHistoryCoverageStore.holes(db, chatId: chatId),
      olderCandidateMessageID: nil,
      newerCandidateMessageID: nil
    )
    let wholeThrough = persistedCoverage.certifiedReadMaxID(after: currentReadMaxID, through: highestVisibleIncomingID)
    return AutomaticReadAdmission(
      maxID: highestVisibleIncomingID,
      crossesGap: wholeThrough != highestVisibleIncomingID
    )
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
    case .invalid, .historyUnavailable, .dependencyFailed:
      false
    }
  }
}

public final class UnreadManager: Sendable {
  public static let shared = UnreadManager()

  private let log = Log.scoped("UnreadManager", enableTracing: false)
  private let db = AppDatabase.shared
  /// When each chat was last marked unread: a visibility pass measured before then must not read
  /// it again.
  private let unreadIntents = Mutex<[Int64: ContinuousClock.Instant]>([:])

  private init() {}

  // This is called when chat opens initially
  public func readMessages(_ maxId: Int64, in peerId: Peer, chatId: Int64) {
    readVisible(peerId: peerId, chatId: chatId, highestVisibleIncomingID: maxId)
  }

  /// Reads what is on screen on this device at once: the cursor and count move in the dialog, so
  /// the chat, chat list, app icon and Dock change together, and `ReadStateSync` pushes the
  /// cursor. Like Telegram's `applyMaxReadIndexInteractively`.
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
        let change = try await db.dbWriter.write { db -> (LocalReadChange, Bool) in
          try Auth.shared.handle.validateAccountMutation(mutationToken)
          // Checked inside the write, which orders it with mark-unread's own write.
          guard !self.isSuperseded(dialogId: dialogId, requestedAt: requestedAt),
                let admission = try AutomaticReadAdmission.resolve(
                  db,
                  peerId: peerId,
                  chatId: chatId,
                  highestVisibleIncomingID: highestVisibleIncomingID
                )
          else { return (.unchanged, false) }
          return (try Dialog.applyLocalRead(db, peerId: peerId, through: admission.maxID), admission.crossesGap)
        }
        afterLocalRead(change.0, peerId: peerId, chatId: chatId, account: mutationToken, validatesCount: change.1)
      } catch is CancellationError {
        return
      } catch {
        log.error("Failed to read visible messages", error: error)
      }
    }
  }

  /// An explicit unread intent supersedes earlier visibility work and any read not sent yet.
  func cancelAutomaticReads(in peerId: Peer) async {
    let dialogId = Dialog.getDialogId(peerId: peerId)
    unreadIntents.withLock { $0[dialogId] = ContinuousClock.now }
    await ReadStateSync.shared.dropPending(peerId)
  }

  private func isSuperseded(dialogId: Int64, requestedAt: ContinuousClock.Instant) -> Bool {
    unreadIntents.withLock { intents in intents[dialogId].map { requestedAt <= $0 } ?? false }
  }

  /// Explicit "Mark as Read" from a chat list or menu: moves the read cursor and also reads
  /// every unseen mention and reaction. Opening a chat uses `readAll`, which keeps them.
  public func markChatRead(_ peerId: Peer, chatId: Int64) {
    readAll(peerId, chatId: chatId)
    Task(priority: .userInitiated) {
      do {
        let maxId = try await db.reader.read { db in try ChatActivityItem.markAllBound(db, chatId: chatId) }
        _ = try await Api.realtime.send(
          .readAllActivity(peerId: peerId, chatId: chatId, kinds: ChatActivityItem.Kind.allCases, maxId: maxId)
        )
      } catch {
        log.error("Failed to clear activity for chat", error: error)
      }
    }
  }

  /// Reads the whole chat on this device: through its last message, count zero, no mark. Used
  /// at the live end of a chat and from a chat list or menu.
  public func readAll(_ peerId: Peer, chatId: Int64) {
    log.trace("readAll")
    let requestedAt = ContinuousClock.now
    guard let mutationToken = try? Auth.shared.handle.beginAccountMutation() else { return }
    let dialogId = Dialog.getDialogId(peerId: peerId)

    Task(priority: .userInitiated) {
      do {
        let change = try await db.dbWriter.write { db -> LocalReadChange in
          try Auth.shared.handle.validateAccountMutation(mutationToken)
          guard !self.isSuperseded(dialogId: dialogId, requestedAt: requestedAt) else { return .unchanged }
          return try Dialog.applyLocalReadToEnd(db, peerId: peerId)
        }
        afterLocalRead(change, peerId: peerId, chatId: chatId, account: mutationToken)
        #if os(iOS)
        // A notification can land for a message already read here; reading the chat clears it.
        if change == .unchanged || change == .clearedMark {
          NotificationCleanup.removeNotifications(
            threadId: "chat_\(chatId)",
            upToMessageId: nil,
            expectedAccount: mutationToken
          )
        }
        #endif
      } catch is CancellationError {
        return
      } catch {
        log.error("Failed to read chat", error: error)
      }
    }
  }

  private func afterLocalRead(
    _ change: LocalReadChange,
    peerId: Peer,
    chatId: Int64,
    account: AuthAccountMutationToken,
    validatesCount: Bool = false
  ) {
    switch change {
    case .unchanged:
      return
    case let .advanced(throughId):
      ReadStateSync.shared.schedule(peerId, validatingCount: validatesCount)
      NotificationCleanup.removeNotifications(
        threadId: "chat_\(chatId)",
        upToMessageId: throughId,
        expectedAccount: account
      )
    case .clearedMark:
      // Nothing for the cursor sync to carry: clear the server's mark with a read of its own.
      Task(priority: .utility) { [log] in
        do {
          _ = try await Api.realtime.send(.readMessages(peerId: peerId, maxId: nil), expectedAccount: account)
        } catch {
          log.error("Failed to clear the unread mark", error: error)
        }
      }
    }
  }
}
