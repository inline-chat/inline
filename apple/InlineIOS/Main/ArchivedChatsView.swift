import InlineKit
import SwiftUI

struct ArchivedChatsView: View {
  enum ArchivedChatsType {
    case home
    case space(spaceId: Int64)
  }

  var type: ArchivedChatsType = .home
  @EnvironmentObject private var home: HomeViewModel
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject var data: DataManager
  @Environment(\.realtime) var realtime
  @Environment(\.appDatabase) private var database
  @EnvironmentObject private var fullSpaceViewModel: FullSpaceViewModel

  var body: some View {
    Group {
      switch type {
        case .home:
          homeArchivedView
        case .space:
          spaceArchivedView
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text("Archived chats")
          .font(.title3)
          .fontWeight(.semibold)
      }
    }
  }

  private var homeArchivedView: some View {
    ChatListView(
      items: chatItems,
      isArchived: true,
      onItemTap: { item in
        if let user = item.user {
          nav.push(.chat(peer: .user(id: user.user.id)))
        } else if let chat = item.chat {
          nav.push(.chat(peer: .thread(id: chat.id)))
        }
      },
      onArchive: { item in
        Task {
          if let user = item.user {
            try await data.updateDialog(
              peerId: .user(id: user.user.id),
              archived: false
            )
          } else if let chat = item.chat {
            try await data.updateDialog(
              peerId: .thread(id: chat.id),
              archived: false
            )
          }
        }
      },
      onPin: { item in
        Task {
          if let user = item.user {
            try await data.updateDialog(
              peerId: .user(id: user.user.id),
              pinned: !(item.dialog.pinned ?? false)
            )
          } else if let chat = item.chat {
            try await data.updateDialog(
              peerId: .thread(id: chat.id),
              pinned: !(item.dialog.pinned ?? false)
            )
          }
        }
      },
      onRead: { item in
        Task {
          UnreadManager.shared.readAll(item.dialog.peerId, chatId: item.chat?.id ?? 0)
        }
      }
    )
  }

  private var chatItems: [HomeChatItem] {
    home.chats.filter { $0.dialog.archived == true }
      .sorted { (item1: HomeChatItem, item2: HomeChatItem) in
        let pinned1 = item1.dialog.pinned ?? false
        let pinned2 = item2.dialog.pinned ?? false
        if pinned1 != pinned2 { return pinned1 }
        return item1.message?.date ?? item1.chat?.date ?? Date.now > item2.message?.date ?? item2.chat?.date ?? Date.now
      }
  }

  private var spaceArchivedView: some View {
    Group {
      let memberItems = fullSpaceViewModel.memberChats.map { SpaceCombinedItem.member($0) }
      let chatItems = fullSpaceViewModel.chats.map { SpaceCombinedItem.chat($0) }
      let allItems = (memberItems + chatItems).filter { item in
        switch item {
          case let .member(memberChat):
            memberChat.dialog.archived == true
          case let .chat(chat):
            chat.dialog.archived == true
        }
      }.sorted { item1, item2 in
        let pinned1 = item1.isPinned
        let pinned2 = item2.isPinned
        if pinned1 != pinned2 { return pinned1 }
        return item1.date > item2.date
      }

      if allItems.isEmpty {
        EmptyChatsView(isArchived: true)
      } else {
        List {
          ForEach(allItems, id: \.id) { item in
            combinedItemRow(for: item)
              .listRowInsets(.init(
                top: 9,
                leading: 16,
                bottom: 2,
                trailing: 0
              ))
          }
        }
        .listStyle(.plain)
        .animation(.default, value: fullSpaceViewModel.chats)
        .animation(.default, value: fullSpaceViewModel.memberChats)
      }
    }
  }

  @ViewBuilder
  private func combinedItemRow(for item: SpaceCombinedItem) -> some View {
    switch item {
      case let .member(memberChat):
        ChatListItem(
          item: HomeChatItem(
            dialog: memberChat.dialog,
            user: memberChat.userInfo,
            chat: memberChat.chat,
            message: memberChat.message,
            from: memberChat.from,
            space: nil
          ),
          onTap: {
            nav.push(.chat(peer: .user(id: memberChat.user?.id ?? 0)))
          },
          onArchive: {
            Task {
              try await data.updateDialog(
                peerId: .user(id: memberChat.user?.id ?? 0),
                archived: false
              )
            }
          },
          onPin: {
            Task {
              try await data.updateDialog(
                peerId: .user(id: memberChat.user?.id ?? 0),
                pinned: !(memberChat.dialog.pinned ?? false)
              )
            }
          },
          onRead: {
            Task {
              UnreadManager.shared.readAll(memberChat.dialog.peerId, chatId: memberChat.chat?.id ?? 0)
            }
          },
          isArchived: true
        )

      case let .chat(chat):
        ChatListItem(
          item: HomeChatItem(
            dialog: chat.dialog,
            user: chat.userInfo,
            chat: chat.chat,
            message: chat.message,
            from: chat.from,
            space: chat.chat?.spaceId != nil ? fullSpaceViewModel.space : nil
          ),
          onTap: {
            nav.push(.chat(peer: chat.peerId))
          },
          onArchive: {
            Task {
              try await data.updateDialog(
                peerId: chat.peerId,
                archived: false
              )
            }
          },
          onPin: {
            Task {
              try await data.updateDialog(
                peerId: chat.peerId,
                pinned: !(chat.dialog.pinned ?? false)
              )
            }
          },
          onRead: {
            Task {
              UnreadManager.shared.readAll(chat.dialog.peerId, chatId: chat.chat?.id ?? 0)
            }
          },
          isArchived: true
        )
    }
  }
}

private enum SpaceCombinedItem: Identifiable {
  case member(SpaceChatItem)
  case chat(SpaceChatItem)

  var id: Int64 {
    switch self {
      case let .member(item): item.user?.id ?? 0
      case let .chat(item): item.id
    }
  }

  var date: Date {
    switch self {
      case let .member(item): item.message?.date ?? item.chat?.date ?? Date()
      case let .chat(item): item.message?.date ?? item.chat?.date ?? Date()
    }
  }

  var isPinned: Bool {
    switch self {
      case let .member(item): item.dialog.pinned ?? false
      case let .chat(item): item.dialog.pinned ?? false
    }
  }
}
