import AsyncAlgorithms
import Combine
import Foundation
import InlineKit

enum MessageListAction {
  case scrollToMsg(ScrollToMessageRequest)
  case scrollToBottom
}

enum ScrollToMessageReason: String, Sendable, Codable {
  case reply
  case pinned
  case forwarded
  case media
  case link
  case search
  case unknown
}

struct ScrollToMessageRequest: Sendable, Equatable {
  let messageId: Int64
  let reason: ScrollToMessageReason
  /// Text of the message to highlight instead of the whole row, for a quote reply.
  var quote: String? = nil
}

class ChatState {
  struct ChatStateData: Codable {
    var replyingToMsgId: Int64?
    var forwardContext: ForwardContext?
    var sendSilently: Bool

    enum CodingKeys: String, CodingKey {
      case replyingToMsgId
      case forwardContext
      case sendSilently
    }

    init(
      replyingToMsgId: Int64? = nil,
      forwardContext: ForwardContext? = nil,
      sendSilently: Bool = false
    ) {
      self.replyingToMsgId = replyingToMsgId
      self.forwardContext = forwardContext
      self.sendSilently = sendSilently
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      replyingToMsgId = try container.decodeIfPresent(Int64.self, forKey: .replyingToMsgId)
      forwardContext = try container.decodeIfPresent(ForwardContext.self, forKey: .forwardContext)
      sendSilently = try container.decodeIfPresent(Bool.self, forKey: .sendSilently) ?? false
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encodeIfPresent(replyingToMsgId, forKey: .replyingToMsgId)
      try container.encodeIfPresent(forwardContext, forKey: .forwardContext)
      try container.encode(sendSilently, forKey: .sendSilently)
    }
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
  public var forwardContext: ForwardContext? {
    data.forwardContext
  }
  public var sendSilently: Bool {
    data.sendSilently
  }

  public let replyingToMsgIdPublisher = PassthroughSubject<Int64?, Never>()
  public let editingMsgIdPublisher = PassthroughSubject<Int64?, Never>()
  public let forwardContextPublisher = PassthroughSubject<ForwardContext?, Never>()
  public let sendSilentlyPublisher = PassthroughSubject<Bool, Never>()
  /// Quote lines for the composer to place before what is already typed.
  public let quotePublisher = PassthroughSubject<String, Never>()

  struct ForwardContext: Codable {
    var fromPeerId: Peer
    var sourceChatId: Int64
    var messageIds: [Int64]
  }

  init(peerId: Peer, chatId: Int64) {
    self.peerId = peerId
    self.chatId = chatId
    data = ChatStateData()
    if let loadedData = load() {
      data = loadedData
    }
  }

  /// Scroll to a message by ID and highlight
  public func scrollTo(msgId: Int64, reason: ScrollToMessageReason = .unknown, quote: String? = nil) {
    Task { @MainActor in
      await events.send(.scrollToMsg(ScrollToMessageRequest(messageId: msgId, reason: reason, quote: quote)))
    }
  }

  /// Scroll to end of chat view
  public func scrollToBottom() {
    Task { @MainActor in
      await events.send(.scrollToBottom)
    }
  }

  public func setReplyingToMsgId(_ id: Int64) {
    clearForwarding()
    data.replyingToMsgId = id
    replyingToMsgIdPublisher.send(id)
    save()
  }

  /// Replies to a message and starts the composer with `markdown` quote lines.
  public func quote(_ markdown: String, replyingTo id: Int64) {
    setReplyingToMsgId(id)
    quotePublisher.send(markdown)
  }

  public func clearReplyingToMsgId() {
    guard data.replyingToMsgId != nil else { return }
    data.replyingToMsgId = nil
    replyingToMsgIdPublisher.send(nil)
    save()
  }

  public func setEditingMsgId(_ id: Int64) {
    clearReplyingToMsgId()
    clearForwarding()
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

  public func setForwardingMessages(
    fromPeerId: Peer,
    sourceChatId: Int64,
    messageIds: [Int64]
  ) {
    clearReplyingToMsgId()
    clearEditingMsgId()
    data.forwardContext = ForwardContext(
      fromPeerId: fromPeerId,
      sourceChatId: sourceChatId,
      messageIds: messageIds
    )
    forwardContextPublisher.send(data.forwardContext)
    save()
  }

  public func clearForwarding() {
    guard data.forwardContext != nil else { return }
    data.forwardContext = nil
    forwardContextPublisher.send(nil)
    save()
  }

  public func setSendSilently(_ enabled: Bool) {
    guard data.sendSilently != enabled else { return }
    data.sendSilently = enabled
    sendSilentlyPublisher.send(enabled)
    save()
  }

  public func toggleSendSilently() {
    setSendSilently(!data.sendSilently)
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
