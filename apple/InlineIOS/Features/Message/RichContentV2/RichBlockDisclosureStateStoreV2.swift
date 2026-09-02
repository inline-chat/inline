import Foundation
import InlineKit

final class RichBlockDisclosureStateStoreV2: @unchecked Sendable {
  static let shared = RichBlockDisclosureStateStoreV2()

  private let lock = NSLock()
  private var values: [BlockContentMessageIdentity: BlockContentDisclosureState] = [:]
  private var recency: [BlockContentMessageIdentity] = []
  private let capacity = 512

  private init() {}

  func overrides(for message: Message) -> [BlockContentPath: Bool] {
    let identity = BlockContentMessageIdentity(message: message)
    return lock.withLock {
      guard var state = values[identity] else { return [:] }
      let overrides = state.overrides(content: message.blockContentPayload, source: message.text ?? "")
      values[identity] = state
      return overrides
    }
  }

  func set(_ expanded: Bool, path: BlockContentPath, message: Message) {
    let identity = BlockContentMessageIdentity(message: message)
    lock.withLock {
      values[identity, default: .init()].set(
        expanded, path: path, content: message.blockContentPayload, source: message.text ?? ""
      )
      recency.removeAll { $0 == identity }
      recency.append(identity)
      while recency.count > capacity {
        values[recency.removeFirst()] = nil
      }
    }
  }
}
