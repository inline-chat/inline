import Foundation

public enum MessageGestureAction: String, CaseIterable, Identifiable, Codable, Sendable {
  case none
  case toggleAck
  case reply
  case toggleHeart
  case toggleThumbsUp
  case reactionsMenu

  public static let defaultDoubleClick: Self = .toggleAck
  public static let defaultHold: Self = .reactionsMenu

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .none:
      return "Nothing"
    case .toggleAck:
      return "Toggle Ack"
    case .reply:
      return "Reply"
    case .toggleHeart:
      return "Toggle heart"
    case .toggleThumbsUp:
      return "Toggle thumbs up"
    case .reactionsMenu:
      return "Reactions menu"
    }
  }

  public var reactionEmoji: String? {
    let emoji: String? = switch self {
    case .toggleAck:
      nil
    case .toggleHeart:
      "❤️"
    case .toggleThumbsUp:
      "👍"
    case .none, .reply, .reactionsMenu:
      nil
    }

    return emoji
  }
}
