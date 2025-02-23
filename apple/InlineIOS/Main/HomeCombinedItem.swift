import InlineKit
import SwiftUI

enum CombinedItem: Identifiable {
  case space(SpaceItem)
  case chat(HomeChatItem)

  var stableId: String {
    switch self {
      case let .chat(chatItem):
        "chat_\(chatItem.dialog.id)"
      case let .space(spaceItem):
        "space_\(spaceItem.space.id)"
    }
  }

  var id: Int64 {
    switch self {
      case let .space(space): space.id
      case let .chat(chat): chat.user.id
    }
  }

  var date: Date {
    switch self {
      case let .space(space): space.space.date
      case let .chat(chat): chat.message?.date ?? chat.chat?.date ?? Date()
    }
  }
}
