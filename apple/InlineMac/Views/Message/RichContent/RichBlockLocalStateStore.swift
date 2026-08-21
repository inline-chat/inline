import Foundation
import InlineKit

extension Notification.Name {
  static let richBlockDisclosureStateDidChange = Notification.Name(
    "chat.inline.richBlockDisclosureStateDidChange"
  )
}

final class RichBlockLocalStateStore: @unchecked Sendable {
  static let shared = RichBlockLocalStateStore()

  private struct MessageIdentity: Hashable {
    let chatID: Int64
    let messageID: Int64
    let randomID: Int64?

    init(message: Message) {
      chatID = message.chatId
      messageID = message.messageId
      randomID = message.messageId == 0 ? message.randomId : nil
    }
  }

  private let lock = NSLock()
  private var disclosureStates: [MessageIdentity: [BlockContentPath: Bool]] = [:]
  private var recency: [MessageIdentity] = []
  private let capacity = 512

  private init() {}

  func disclosureOverrides(for message: Message) -> [BlockContentPath: Bool] {
    let identity = MessageIdentity(message: message)
    lock.lock()
    defer { lock.unlock() }
    return disclosureStates[identity] ?? [:]
  }

  func setDisclosure(_ expanded: Bool, path: BlockContentPath, message: Message) {
    let identity = MessageIdentity(message: message)
    lock.lock()
    disclosureStates[identity, default: [:]][path] = expanded
    recency.removeAll { $0 == identity }
    recency.append(identity)
    while recency.count > capacity {
      disclosureStates[recency.removeFirst()] = nil
    }
    lock.unlock()
    Task { @MainActor in
      NotificationCenter.default.post(
        name: .richBlockDisclosureStateDidChange,
        object: self,
        userInfo: ["messageStableID": message.stableId]
      )
    }
  }
}
