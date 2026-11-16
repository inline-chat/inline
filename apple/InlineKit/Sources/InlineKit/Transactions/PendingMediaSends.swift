import Combine
import Foundation
import InlineProtocol

/// A message with attachments that is queued or sending, as the transaction runner sees it.
public struct PendingMediaSend: Sendable {
  public let transactionId: String
  public let chatId: Int64
  public let temporaryMessageId: Int64
  public let media: [FileMediaItem]
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
      temporaryMessageId: temporaryMessageId,
      media: attachments.map(\.media)
    )
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
