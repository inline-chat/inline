import Foundation
import InlineKit

enum MessageListSectionID: Hashable {
  case messages(dayStart: Date)
  case threadContext
  case collapsedHistory

  var showsDateSeparator: Bool {
    switch self {
      case .messages:
        true
      case .threadContext, .collapsedHistory:
        false
    }
  }
}

struct MessageListSection {
  var id: MessageListSectionID
  var dayString: String?
  var items: [MessageListItem]
}

enum MessageListItem: Hashable {
  case message(id: Int64)
  case threadAnchor(id: Int64)
  case unreadSeparator(id: String)
  case clearedHistory(maxId: Int64)

  var messageStableId: Int64? {
    switch self {
      case let .message(id), let .threadAnchor(id):
        id
      case .unreadSeparator, .clearedHistory:
        nil
    }
  }

  var isThreadAnchor: Bool {
    if case .threadAnchor = self {
      return true
    }
    return false
  }
}

struct MessageListItemModel {
  enum Content {
    case message(FullMessage, displayMode: MessageDisplayMode)
    case unreadSeparator(title: String)
    case clearedHistory(title: String)
  }

  var content: Content
}
