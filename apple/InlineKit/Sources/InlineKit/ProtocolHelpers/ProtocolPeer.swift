import Auth
import InlineProtocol
import Logger

public extension InlineProtocol.Peer {
  func toPeer() -> Peer {
    switch type {
      case let .user(value):
        return Peer.user(id: value.userID)
      case let .chat(value):
        return Peer.thread(id: value.chatID)
      default:
        Log.shared.error("Unknown peer type")
        return Peer.user(id: 0)
    }
  }
}

public extension InlineProtocol.InputPeer {
  func toPeer() -> Peer {
    switch type {
      case let .user(value):
        return Peer.user(id: value.userID)
      case let .chat(value):
        return Peer.thread(id: value.chatID)
      case .self_p:
        let currentUserId = Auth.shared.getCurrentUserId()
        return Peer.user(id: currentUserId ?? 0)
      default:
        Log.shared.error("Unknown peer type")
        return Peer.user(id: 0)
    }
  }
}

public extension Peer {
  func toInputPeer() -> InlineProtocol.InputPeer {
    switch self {
      case let .user(id):
        InlineProtocol.InputPeer.with { inputPeer in
          inputPeer.type = .user(.with { user in
            user.userID = id
          })
        }

      case let .thread(id):
        InlineProtocol.InputPeer.with { inputPeer in
          inputPeer.type = .chat(.with { chat in
            chat.chatID = id
          })
        }
    }
  }
}
