import Foundation
import SwiftUI

@MainActor
final class ChatState: ObservableObject {
  static let shared = ChatState()

  @Published private(set) var replyingMessageId: Int64? {
    didSet {
      persistReplyingMessageId()
    }
  }

  private let defaults = UserDefaults.standard
  private let replyingMessageIdKey = "replyingMessageId"

  init() {
    loadPersistedReplyingMessageId()
    print("ChatState init, \(String(describing: replyingMessageId))")
  }

  func setReplyingMessageId(id: Int64) {
    print("setReplyingMessageId, \(id)")
    replyingMessageId = id
  }

  func clearReplyingMessageId() {
    print("clearReplyingMessageId, \(String(describing: replyingMessageId))")
    replyingMessageId = nil
  }

  private func persistReplyingMessageId() {
    if let id = replyingMessageId {
      defaults.set(id, forKey: replyingMessageIdKey)
    } else {
      defaults.removeObject(forKey: replyingMessageIdKey)
    }
  }

  private func loadPersistedReplyingMessageId() {
    if defaults.object(forKey: replyingMessageIdKey) != nil {
      replyingMessageId = Int64(defaults.integer(forKey: replyingMessageIdKey))
    }
  }
}
