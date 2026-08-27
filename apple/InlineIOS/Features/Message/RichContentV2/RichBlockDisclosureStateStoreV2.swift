import Foundation
import InlineKit

final class RichBlockDisclosureStateStoreV2: @unchecked Sendable {
  static let shared = RichBlockDisclosureStateStoreV2()

  private struct MessageIdentity: Hashable {
    let chatID: Int64
    let stableID: Int64

    init(_ message: Message) {
      chatID = message.chatId
      if let randomID = message.randomId, randomID != 0 {
        stableID = randomID
      } else if let globalID = message.globalId, globalID != 0 {
        stableID = globalID
      } else {
        stableID = message.messageId
      }
    }
  }

  private let lock = NSLock()
  private var values: [MessageIdentity: [BlockContentPath: Bool]] = [:]
  private var recency: [MessageIdentity] = []
  private let capacity = 512

  private init() {}

  func overrides(for message: Message) -> [BlockContentPath: Bool] {
    lock.withLock { values[MessageIdentity(message)] ?? [:] }
  }

  func set(_ expanded: Bool, path: BlockContentPath, message: Message) {
    let identity = MessageIdentity(message)
    lock.withLock {
      values[identity, default: [:]][path] = expanded
      recency.removeAll { $0 == identity }
      recency.append(identity)
      while recency.count > capacity {
        values[recency.removeFirst()] = nil
      }
    }
  }
}
