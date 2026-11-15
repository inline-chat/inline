import Combine
import Foundation

/// Text a message asks to put in a chat's composer: a compose action or a prompt
/// suggestion. Composers for that peer listen, add the text after any draft (on its own
/// line) and focus the editor, like a prefilled prompt. Nothing is ever sent from here.
@MainActor
public final class MessageComposeRequests {
  public struct Request: Equatable, Sendable {
    /// The chat of the message that asked.
    public let peer: Peer
    public let text: String
    /// The message that asked, when known.
    public let chatID: Int64?
    public let messageID: Int64?
    /// The message was shown as the anchor at the top of its reply thread, so the
    /// thread's composer takes the text rather than the parent chat's.
    public let isThreadAnchor: Bool

    public init(peer: Peer, text: String, chatID: Int64? = nil, messageID: Int64? = nil, isThreadAnchor: Bool = false) {
      self.peer = peer
      self.text = text
      self.chatID = chatID
      self.messageID = messageID
      self.isThreadAnchor = isThreadAnchor
    }

    /// Whether `chat` is the reply thread anchored on the message that asked.
    public func isAnchor(of chat: Chat?) -> Bool {
      guard let chat, let chatID, let messageID else { return false }
      return chat.parentChatId == chatID && chat.parentMessageId == messageID
    }

    /// Whether the composer for `peer` (whose chat is `chat`) takes this request. An
    /// anchor's request goes only to its thread, so a window showing both the parent
    /// chat and the thread fills one composer.
    public func targets(peer composerPeer: Peer?, chat: Chat?) -> Bool {
      isThreadAnchor ? isAnchor(of: chat) : composerPeer == peer
    }
  }

  public static let shared = MessageComposeRequests()

  private let subject = PassthroughSubject<Request, Never>()

  public var requests: AnyPublisher<Request, Never> { subject.eraseToAnyPublisher() }

  /// Posts `text` for the composer of `message`'s chat, or of its reply thread when the
  /// message is shown as that thread's anchor. Empty text is dropped.
  public func post(_ text: String, from message: Message, isThreadAnchor: Bool = false) {
    guard case let .compose(trimmed) = MessageActionPresentation.composeIntent(text) else { return }
    subject.send(Request(
      peer: message.peerId,
      text: trimmed,
      chatID: message.chatId,
      messageID: message.messageId,
      isThreadAnchor: isThreadAnchor
    ))
  }

  /// Posts `text` for `peer`'s composer. Empty text is dropped.
  public func post(_ text: String, for peer: Peer) {
    guard case let .compose(trimmed) = MessageActionPresentation.composeIntent(text) else { return }
    subject.send(Request(peer: peer, text: trimmed))
  }
}
