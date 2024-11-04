import Foundation
import GRDB

public enum ChatPeer: Hashable, Equatable {
  case privateChat(userId: Int64)
  case thread(chatId: Int64)

  public var isPrivate: Bool {
    switch self {
    case .privateChat:
      return true
    case .thread:
      return false
    }
  }

  public func hash(into hasher: inout Hasher) {
    switch self {
    case let .privateChat(userId):
      hasher.combine(0)
      hasher.combine(userId)
    case let .thread(chatId):
      hasher.combine(1)
      hasher.combine(chatId)
    }
  }

  public static func == (lhs: ChatPeer, rhs: ChatPeer) -> Bool {
    switch (lhs, rhs) {
    case let (.privateChat(lhsId), .privateChat(rhsId)):
      return lhsId == rhsId
    case let (.thread(lhsId), .thread(rhsId)):
      return lhsId == rhsId
    default:
      return false
    }
  }
}
