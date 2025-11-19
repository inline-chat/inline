import Logger

public extension Peer {
  func toInputPeer() -> InputPeer {
    switch type {
    case let .user(value):
      return .with {
        $0.user.userID = value.userID
      }

    case let .chat(value):
      return .with {
        $0.chat.chatID = value.chatID
      }

    default:
      Log.shared.error("Unknown peer type")
      return .with {
        $0.user.userID = 0
      }
    }
  }
}
