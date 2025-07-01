import InlineKit
import SwiftUI

struct ChatListView: View {
  let items: [HomeChatItem]
  let isArchived: Bool
  let onItemTap: (HomeChatItem) -> Void
  let onArchive: (HomeChatItem) -> Void
  let onPin: (HomeChatItem) -> Void
  let onRead: (HomeChatItem) -> Void

  @Environment(Router.self) private var router
  @State private var previousItems: [HomeChatItem] = []

  var body: some View {
    if items.isEmpty {
      EmptyChatsView(isArchived: isArchived)
    } else {
      List {
        ForEach(items, id: \.id) { item in
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
      .onChange(of: items) { _, newItems in
        processForTranslation(items: newItems)
        previousItems = newItems
      }
    }
  }

  func processForTranslation(items: [HomeChatItem]) {
    let currentPath = router.selectedTabPath

    let itemsToProcess = items.filter { newItem in
      if let oldItem = previousItems.first(where: { $0.id == newItem.id }) {
        return oldItem != newItem
      }
      return true
    }

    Task.detached {
      for item in itemsToProcess {
        let isCurrentChat = currentPath.contains { destination in
          if case let .chat(peer) = destination {
            return peer == item.peerId
          }
          return false
        }
        guard !isCurrentChat else { return }

        guard let lastMessage = item.lastMessage else { return }
        TranslationViewModel.translateMessages(for: item.peerId, messages: [FullMessage(from: lastMessage)])
      }
    }
  }
}
