import InlineKit
import SwiftUI

struct ChatListView: View {
  let items: [HomeChatItem]
  let isArchived: Bool
  let onItemTap: (HomeChatItem) -> Void
  let onArchive: (HomeChatItem) -> Void
  let onPin: (HomeChatItem) -> Void
  let onRead: (HomeChatItem) -> Void

  var body: some View {
    if items.isEmpty {
      EmptyChatsView(isArchived: isArchived)
    } else {
      List {
        ForEach(items, id: \.self) { item in
          ChatListItem(
            item: item,
            onTap: { onItemTap(item) },
            onArchive: { onArchive(item) },
            onPin: { onPin(item) },
            onRead: { onRead(item) },
            isArchived: isArchived
          )
        }
      }
      .listStyle(.plain)
      .animation(.default, value: items)
    }
  }
}
