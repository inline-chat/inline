import Combine
import Foundation
import InlineKit

enum MessageListAction {
  case scrollToMsg(Int64)
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
  private var highlightedMsgId: Int64?

  public var replyingToMsgId: Int64? {
    data.replyingToMsgId
  }

  public let replyingToMsgIdPublisher = PassthroughSubject<Int64?, Never>()

  init(peerId: Peer, chatId: Int64) {
    self.peerId = peerId
    self.chatId = chatId
    data = ChatStateData()
    if let loadedData = load() {
      data = loadedData
    }
  }

  public func highlight(msgId: Int64) {
    highlightedMsgId = msgId
  }

  public func setReplyingToMsgId(_ id: Int64) {
    data.replyingToMsgId = id
    replyingToMsgIdPublisher.send(id)
    save()
  }

  public func clearReplyingToMsgId() {
    data.replyingToMsgId = nil
    replyingToMsgIdPublisher.send(nil)
    save()
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
