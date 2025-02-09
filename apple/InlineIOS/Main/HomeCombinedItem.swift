import InlineKit
import SwiftUI

enum CombinedItem: Identifiable {
  case space(SpaceItem)
  case chat(HomeChatItem)

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
