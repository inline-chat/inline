import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger

/// A message with attachments that is queued or sending, as the transaction runner sees it.
public struct PendingMediaSend: Sendable {
  public let transactionId: String
  public let chatId: Int64
  public let peerId: Peer
  public let temporaryMessageId: Int64
  public let media: [FileMediaItem]
  /// Set when the send is one item of an album.
  public var groupedId: Int64? = nil
}

/// The media sends this process is working on, from admission until they succeed, fail or are
/// cancelled. Background time and the iOS continued-processing task follow this set, so it holds
/// only work that is really running, never a row left in `sending` by an earlier launch.
public final class PendingMediaSends: @unchecked Sendable {
  public static let shared = PendingMediaSends()

  private let lock = NSLock()
  /// Counted per id: a Retry can admit the same transaction id again before the failed run
  /// has left, and that run's exit must not drop the new one.
  private var sends: [String: (send: PendingMediaSend, count: Int)] = [:]
  private let subject = CurrentValueSubject<[PendingMediaSend], Never>([])

  public init() {}

  /// Current sends, in no particular order.
  public var current: [PendingMediaSend] {
    lock.withLock { sends.values.map(\.send) }
  }

  /// Emits the whole set on every change, starting with the current one.
  public var publisher: AnyPublisher<[PendingMediaSend], Never> {
    subject.eraseToAnyPublisher()
  }

  func insert(_ send: PendingMediaSend) {
    let snapshot: [PendingMediaSend]? = lock.withLock {
      if let entry = sends[send.transactionId] {
        sends[send.transactionId] = (entry.send, entry.count + 1)
        return nil
      }
      sends[send.transactionId] = (send, 1)
      return sends.values.map(\.send)
    }
    if let snapshot { subject.send(snapshot) }
  }

  func remove(transactionId: String) {
    let snapshot: [PendingMediaSend]? = lock.withLock {
      guard let entry = sends[transactionId] else { return nil }
      if entry.count > 1 {
        sends[transactionId] = (entry.send, entry.count - 1)
        return nil
      }
      sends.removeValue(forKey: transactionId)
      return sends.values.map(\.send)
    }
    if let snapshot { subject.send(snapshot) }
  }
}

extension TransactionSendMessage {
  public var pendingMediaSend: PendingMediaSend? {
    guard !attachments.isEmpty else { return nil }
    return PendingMediaSend(
      transactionId: id,
      chatId: chatId,
      peerId: peerId,
      temporaryMessageId: temporaryMessageId,
      media: attachments.map(\.media),
      groupedId: groupedId
    )
  }

  /// Media sends only. A text send keeps its execution timeout, which would run while it waits
  /// its turn behind the chat's uploads, so it stays in the general lane, where it starts only
  /// when a slot frees up (as before). Each lane is FIFO, so cross-lane turns cannot deadlock.
  public var runsInSendLane: Bool { !attachments.isEmpty }
}

public extension PendingMediaSends {
  /// Gives up on sends, as the user's cancel would, and deletes their message rows before
  /// returning. The process may be suspended or killed right after (an expired background
  /// task), and a row still `sending` would be resumed on the next launch.
  @MainActor
  static func deleteUnsent(_ sends: [PendingMediaSend], database: AppDatabase = .shared) {
    guard !sends.isEmpty else { return }
    for send in sends {
      if let message = try? FullMessage.get(messageId: send.temporaryMessageId, chatId: send.chatId),
         PendingMessageCanceller.cancel(message)
      {
        continue
      }
      Transactions.shared.cancel(transactionId: send.transactionId)
    }
    let deleted: [PendingMediaSend]
    do {
      deleted = try database.dbWriter.write { db in
        try sends.filter { send in
          guard let stored = try Message.fetchOne(db, key: [
            "messageId": send.temporaryMessageId, "chatId": send.chatId,
          ]), stored.status == .sending else { return false }
          try Message.deleteMessages(db, messageIds: [send.temporaryMessageId], chatId: send.chatId)
          return true
        }
      }
    } catch {
      Log.shared.error("Failed to delete unsent media messages", error: error)
      return
    }
    for send in deleted {
      MessagesPublisher.shared.messagesDeleted(messageIds: [send.temporaryMessageId], peer: send.peerId)
    }
  }
}

public extension PendingMediaSends {
  /// The sends to give up on when the system ends background time early (Mo, 2026-11-15, as
  /// Telegram does): those whose upload was moving within `movingWindow`. A send that never
  /// started or stalled (waiting for the network) stays queued, and one whose upload finished is
  /// already being sent. An album goes or stays whole: if any item goes, every unsent item of it
  /// goes too, so recipients never get half an album.
  static func expiredSendsToDelete(
    current: [PendingMediaSend],
    taskSendIDs: Set<String>,
    fractions: [String: Double],
    lastMoved: [String: ContinuousClock.Instant],
    now: ContinuousClock.Instant,
    movingWindow: Duration
  ) -> [PendingMediaSend] {
    expiredSendsToDelete(
      current: current, taskSendIDs: taskSendIDs, fractions: fractions, lastMoved: lastMoved,
      now: now, movingWindow: movingWindow,
      isHeldForAlbum: { AlbumSendBarrier.shared.isRegistered(transactionId: $0) }
    )
  }

  /// `isHeldForAlbum`: the item still waits for its album's uploads, so it has not been sent.
  internal static func expiredSendsToDelete(
    current: [PendingMediaSend],
    taskSendIDs: Set<String>,
    fractions: [String: Double],
    lastMoved: [String: ContinuousClock.Instant],
    now: ContinuousClock.Instant,
    movingWindow: Duration,
    isHeldForAlbum: (String) -> Bool
  ) -> [PendingMediaSend] {
    let moving = Set(current.compactMap { send -> String? in
      let id = send.transactionId
      guard taskSendIDs.contains(id), let fraction = fractions[id], fraction > 0, fraction < 1,
            let moved = lastMoved[id], now - moved < movingWindow else { return nil }
      return id
    })
    let albums = Set(current.filter { moving.contains($0.transactionId) }.compactMap(\.groupedId))
    return current.filter { send in
      let id = send.transactionId
      if moving.contains(id) { return true }
      guard let album = send.groupedId, albums.contains(album) else { return false }
      // A sibling whose upload finished and that the album no longer holds is already on its way
      // to the server (the album was released, e.g. by another item's failed upload): leave it.
      return (fractions[id] ?? 0) < 1 || isHeldForAlbum(id)
    }
  }
}

/// Overall progress of a set of sends for a system progress indicator. Each send counts
/// equally; a send never goes backwards (a retry restarts its upload), and one that left the
/// set counts as done, so the bar only moves forward while the set drains.
public struct PendingSendsProgress {
  public private(set) var fractions: [String: Double] = [:]

  public init() {}

  public mutating func update(_ current: [String: Double]) {
    for (key, fraction) in current {
      fractions[key] = max(fractions[key] ?? 0, min(1, max(0, fraction)))
    }
    for key in fractions.keys where current[key] == nil {
      fractions[key] = 1
    }
  }

  /// Completed and total units, at a resolution of 1000 per send.
  public var units: (completed: Int64, total: Int64) {
    let precision: Int64 = 1_000
    let total = Int64(max(1, fractions.count)) * precision
    let completed = fractions.values.reduce(Int64(0)) { $0 + Int64(($1 * Double(precision)).rounded(.down)) }
    return (min(total, completed), total)
  }
}
