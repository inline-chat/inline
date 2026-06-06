import Foundation
import InlineKit

enum MessageListSectionID: Hashable {
  case messages(dayStart: Date)
  case threadContext

  var showsDateSeparator: Bool {
    switch self {
      case .messages:
        true
      case .threadContext:
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

  var messageStableId: Int64? {
    switch self {
      case let .message(id), let .threadAnchor(id):
        id
      case .unreadSeparator:
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
  }

  var content: Content
}
