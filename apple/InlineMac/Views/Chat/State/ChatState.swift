import AsyncAlgorithms
import Combine
import Foundation
import InlineKit

enum MessageListAction {
  case scrollToMsg(Int64)
  case scrollToBottom
}

class ChatState {
  struct ChatStateData: Codable {
    var replyingToMsgId: Int64?
  }

  // Static
  let peerId: Peer
  let chatId: Int64

  // MARK: - State

  private var data: ChatStateData

  @MainActor public var events = AsyncChannel<MessageListAction>()

  public var replyingToMsgId: Int64? {
    data.replyingToMsgId
  }

  public var editingMsgId: Int64?

  public let replyingToMsgIdPublisher = PassthroughSubject<Int64?, Never>()
  public let editingMsgIdPublisher = PassthroughSubject<Int64?, Never>()

  init(peerId: Peer, chatId: Int64) {
    self.peerId = peerId
    self.chatId = chatId
    data = ChatStateData()
    if let loadedData = load() {
      data = loadedData
    }
  }

  /// Scroll to a message by ID and highlight
  public func scrollTo(msgId: Int64) {
    Task { @MainActor in
      await events.send(.scrollToMsg(msgId))
    }
  }

  /// Scroll to end of chat view
  public func scrollToBottom() {
    Task { @MainActor in
      await events.send(.scrollToBottom)
    }
  }

  public func setReplyingToMsgId(_ id: Int64) {
    data.replyingToMsgId = id
    replyingToMsgIdPublisher.send(id)
    save()
  }

  public func clearReplyingToMsgId() {
    guard data.replyingToMsgId != nil else { return }
    data.replyingToMsgId = nil
    replyingToMsgIdPublisher.send(nil)
    save()
  }

  public func setEditingMsgId(_ id: Int64) {
    clearReplyingToMsgId()
    editingMsgId = id
    editingMsgIdPublisher.send(id)
  }

  /// Clears editing message ID and publishes the event if it was set
  ///
  /// Editing message ID does not need to be saved
  public func clearEditingMsgId() {
    guard editingMsgId != nil else { return }
    editingMsgId = nil
    editingMsgIdPublisher.send(nil)
  }

  // MARK: - Persistance

  private var userDefaultsKey: String {
    "chat_state_\(peerId)"
  }

  private func load() -> ChatStateData? {
    guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
          let parsed = try? JSONDecoder().decode(ChatStateData.self, from: data)
    else {
      return nil
    }

    return parsed
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(data) else {
      return
    }
    UserDefaults.standard.set(data, forKey: userDefaultsKey)
  }
}
