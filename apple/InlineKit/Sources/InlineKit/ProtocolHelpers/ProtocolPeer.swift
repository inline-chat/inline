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
