import Foundation
import InlineKit

extension Notification.Name {
  static let richBlockLayoutStateDidChange = Notification.Name(
    "chat.inline.richBlockLayoutStateDidChange"
  )
}

final class RichBlockLocalStateStore: @unchecked Sendable {
  static let shared = RichBlockLocalStateStore()

  private let lock = NSLock()
  private var disclosureStates: [BlockContentMessageIdentity: BlockContentDisclosureState] = [:]
  private var recency: [BlockContentMessageIdentity] = []
  private let capacity = 512

  private init() {}

  func disclosureOverrides(for message: Message) -> [BlockContentPath: Bool] {
    let identity = BlockContentMessageIdentity(message: message)
    lock.lock()
    defer { lock.unlock() }
    guard var state = disclosureStates[identity] else { return [:] }
    let overrides = state.overrides(content: message.blockContentPayload, source: message.text ?? "")
    disclosureStates[identity] = state
    return overrides
  }

  func setDisclosure(_ expanded: Bool, path: BlockContentPath, message: Message) {
    let identity = BlockContentMessageIdentity(message: message)
    lock.lock()
    disclosureStates[identity, default: .init()].set(
      expanded, path: path, content: message.blockContentPayload, source: message.text ?? ""
    )
    recency.removeAll { $0 == identity }
    recency.append(identity)
    while recency.count > capacity {
      disclosureStates[recency.removeFirst()] = nil
    }
    lock.unlock()
    Task { @MainActor in
      NotificationCenter.default.post(
        name: .richBlockLayoutStateDidChange,
        object: self,
        userInfo: ["messageStableID": message.stableId]
      )
    }
  }
}
