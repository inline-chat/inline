import InlineKit
import SwiftUI
import Translation

struct ChatListView: View {
  let items: [HomeChatItem]
  let isArchived: Bool
  let onItemTap: (HomeChatItem) -> Void
  let onArchive: (HomeChatItem) -> Void
  let onPin: (HomeChatItem) -> Void
  let onRead: (HomeChatItem) -> Void
  let onUnread: (HomeChatItem) -> Void
  let showPinnedStyling: Bool
  let showPinAction: Bool

  init(
    items: [HomeChatItem],
    isArchived: Bool,
    showPinnedStyling: Bool = true,
    showPinAction: Bool = true,
    onItemTap: @escaping (HomeChatItem) -> Void,
    onArchive: @escaping (HomeChatItem) -> Void,
    onPin: @escaping (HomeChatItem) -> Void,
    onRead: @escaping (HomeChatItem) -> Void,
    onUnread: @escaping (HomeChatItem) -> Void
  ) {
    self.items = items
    self.isArchived = isArchived
    self.showPinnedStyling = showPinnedStyling
    self.onItemTap = onItemTap
    self.onArchive = onArchive
    self.onPin = onPin
    self.onRead = onRead
    self.onUnread = onUnread
    self.showPinAction = showPinAction
  }

  @Environment(Router.self) private var router
  @State private var previousItems: [HomeChatItem] = []

  var body: some View {
    if items.isEmpty {
      EmptyChatsView(isArchived: isArchived)
    } else {
      List {
        ForEach(items, id: \.id) { item in
          chatRow(for: item)
            .listRowInsets(EdgeInsets(
              top: 8,
              leading: 16,
              bottom: 8,
              trailing: 16
            ))
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

  @ViewBuilder
  private func chatRow(for item: HomeChatItem) -> some View {
    let isPinned = item.dialog.pinned == true

    Button {
      onItemTap(item)
    } label: {
      if let user = item.user {
        ChatListItem(
          type: .user(user, chat: item.chat),
          dialog: item.dialog,
          lastMessage: item.lastMessage?.message,
          lastMessageSender: item.lastMessage?.senderInfo,
          embeddedLastMessage: item.lastMessage,
          showsPinnedIndicator: showPinAction
        )
      } else if let chat = item.chat {
        ChatListItem(
          type: .chat(chat, spaceName: item.space?.name),
          dialog: item.dialog,
          lastMessage: item.lastMessage?.message,
          lastMessageSender: item.lastMessage?.senderInfo,
          embeddedLastMessage: item.lastMessage,
          showsPinnedIndicator: showPinAction
        )
      } else {
        EmptyView()
      }
    }
    .listRowBackground(rowBackground(isPinned: isPinned))
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      readUnreadButton(for: item)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      archiveButton(for: item)
      if showPinAction {
        pinButton(for: item)
      }
    }
  }

  @ViewBuilder
  private func pinButton(for item: HomeChatItem) -> some View {
    let isPinned = item.dialog.pinned ?? false

    Button {
      onPin(item)
    } label: {
      Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
    }
    .tint(.indigo)
  }

  @ViewBuilder
  private func archiveButton(for item: HomeChatItem) -> some View {
    Button(role: isArchived ? nil : .destructive) {
      onArchive(item)
    } label: {
      Label(
        isArchived ? "Unarchive" : "Archive",
        systemImage: isArchived ? "tray.and.arrow.up.fill" : "tray.and.arrow.down.fill"
      )
    }
    .tint(Color(.systemPurple))
  }

  @ViewBuilder
  private func readUnreadButton(for item: HomeChatItem) -> some View {
    let hasUnread = (item.dialog.unreadCount ?? 0) > 0 || item.dialog.unreadMark == true

    Button {
      if hasUnread {
        onRead(item)
      } else {
        onUnread(item)
      }
    } label: {
      Label(
        hasUnread ? "Mark Read" : "Mark Unread",
        systemImage: hasUnread ? "checkmark.message.fill" : "envelope.badge.fill"
      )
    }
    .tint(.blue)
  }

  private func processForTranslation(items: [HomeChatItem]) {
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

  private func rowBackground(isPinned: Bool) -> Color {
    guard showPinnedStyling else {
      return Color(.systemBackground)
    }
    return isPinned ? Color(.systemGray6).opacity(0.5) : Color(.systemBackground)
  }
}
