import Foundation

/// What a chat info page describes. Both apps derive the header, action row,
/// cards, tabs and menus of chat info from this, so they stay in step.
public struct PeerInfoSubject: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// The viewer’s own DM, a place for notes to self.
    case selfChat
    case person
    case bot
    /// A top-level thread, in a space or in Home.
    case thread
    /// A thread under another chat: a reply thread started from a message, or
    /// a structural subthread.
    case subthread
  }

  public var kind: Kind
  public var peer: Peer
  /// The thread's space; nil for Home threads and DMs.
  public var spaceId: Int64?
  /// Public space threads: everyone in the space can read and join.
  public var isPublic: Bool
  /// The chat a subthread lives under.
  public var parentChatId: Int64?
  /// The message a reply thread was started from, inside `parentChatId`.
  public var parentMessageId: Int64?

  public init(
    kind: Kind,
    peer: Peer,
    spaceId: Int64? = nil,
    isPublic: Bool = false,
    parentChatId: Int64? = nil,
    parentMessageId: Int64? = nil
  ) {
    self.kind = kind
    self.peer = peer
    self.spaceId = spaceId
    self.isPublic = isPublic
    self.parentChatId = parentChatId
    self.parentMessageId = parentMessageId
  }

  /// Classifies a peer from whatever is cached. A thread whose chat isn't
  /// cached yet reads as a private top-level thread until it loads.
  public static func resolve(peer: Peer, chat: Chat?, user: User?, currentUserId: Int64?) -> PeerInfoSubject {
    switch peer {
    case let .user(id):
      if let currentUserId, id == currentUserId {
        return PeerInfoSubject(kind: .selfChat, peer: peer)
      }
      return PeerInfoSubject(kind: user?.bot == true ? .bot : .person, peer: peer)
    case .thread:
      let isSubthread = chat?.parentChatId != nil || chat?.parentMessageId != nil
      return PeerInfoSubject(
        kind: isSubthread ? .subthread : .thread,
        peer: peer,
        spaceId: chat?.spaceId,
        isPublic: chat?.isPublic == true,
        parentChatId: chat?.parentChatId,
        parentMessageId: chat?.parentMessageId
      )
    }
  }

  public var isDirect: Bool {
    switch kind {
    case .selfChat, .person, .bot: true
    case .thread, .subthread: false
    }
  }

  public var isThread: Bool { !isDirect }

  /// Home threads have no space, and so no public/private choice.
  public var isHomeThread: Bool { kind == .thread && spaceId == nil }
}
