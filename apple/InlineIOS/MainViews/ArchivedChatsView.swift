import InlineKit
import Logger
import RealtimeV2
import SwiftUI

struct ArchivedChatsView: View {
  enum ArchivedChatsType {
    case home
    case space(spaceId: Int64)
  }

  var type: ArchivedChatsType = .home
  @EnvironmentObject private var home: HomeViewModel
  @Environment(Router.self) private var router
  @EnvironmentObject var data: DataManager
  @Environment(\.realtime) var realtime
  @Environment(\.realtimeV2) var realtimeV2
  @Environment(\.appDatabase) private var database
  @EnvironmentObject private var fullSpaceViewModel: FullSpaceViewModel

  @EnvironmentObject var realtimeState: RealtimeState
  @State var shouldShow = false

  var body: some View {
    Group {
      switch type {
        case .home:
          homeArchivedView
        case .space:
          spaceArchivedView
      }
    }
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
    .toolbar {
      ToolbarItem(placement: .principal) {
        header
      }
    }
  }

  @ViewBuilder
  private var header: some View {
    HStack(spacing: 8) {
      if realtimeState.connectionState != .connected {
        Spinner(size: 16)
          .padding(.trailing, 4)
      }

      VStack(alignment: .leading, spacing: 0) {
        Text(shouldShow ? realtimeState.connectionState.title : "Chats")
          .font(.title3)
          .fontWeight(.semibold)
            
          .contentTransition(.numericText())
          .animation(.spring(duration: 0.5), value: realtimeState.connectionState.title)
          .animation(.spring(duration: 0.5), value: shouldShow)
      }
    }

    .onAppear {
      if realtimeState.connectionState != .connected {
        shouldShow = true
      }
    }
    .onReceive(realtimeState.connectionStatePublisher, perform: { nextConnectionState in
      if nextConnectionState == .connected {
        Task { @MainActor in
          try await Task.sleep(for: .seconds(1))
          if nextConnectionState == .connected {
            // second check
            shouldShow = false
          }
        }
      } else {
        shouldShow = true
      }
    })
  }

  private var homeArchivedView: some View {
    ChatListView(
      items: chatItems,
      isArchived: true,
      onItemTap: { item in
        if let user = item.user {
          router.push(.chat(peer: .user(id: user.user.id)))
        } else if let chat = item.chat {
          router.push(.chat(peer: .thread(id: chat.id)))
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
      },
      onUnread: { item in
        Task {
          do {
            try await realtimeV2.send(.markAsUnread(peerId: item.dialog.peerId))
          } catch {
            Log.shared.error("Failed to mark as unread", error: error)
          }
        }
      }
    )
  }

  private var chatItems: [HomeChatItem] {
    home.archivedChats
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
              //ListRow()
              .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                  toggleReadState(item)
                } label: {
                  Label(item.hasUnread ? "Mark Read" : "Mark Unread", systemImage: item.hasUnread ? "checkmark.message.fill" : "envelope.badge.fill")
                }
                .tint(.blue)
              }
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                  togglePin(item)
                } label: {
                  Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill")
                }
                .tint(.indigo)

                Button(role: item.dialog.archived == true ? nil : .destructive) {
                  toggleArchive(item)
                } label: {
                  Label(item.dialog.archived == true ? "Unarchive" : "Archive", systemImage: item.dialog.archived == true ? "tray.and.arrow.up.fill" : "tray.and.arrow.down.fill")
                }
                .tint(Color(.systemPurple))
              }
          }
        }
          
        .animation(.default, value: fullSpaceViewModel.chats)
        .animation(.default, value: fullSpaceViewModel.memberChats)
      }
    }
  }

  @ViewBuilder
  private func combinedItemRow(for item: SpaceCombinedItem) -> some View {
    switch item {
      case let .member(memberChat):
        if let userInfo = memberChat.userInfo {
          ChatListItem(
            type: .user(userInfo, chat: memberChat.chat),
            dialog: memberChat.dialog,
            lastMessage: memberChat.message,
            lastMessageSender: memberChat.from
          )
          .contentShape(Rectangle())
          .onTapGesture {
            router.push(.chat(peer: .user(id: memberChat.user?.id ?? 0)))
          }
        }

      case let .chat(chat):
        if let chatInfo = chat.chat {
          ChatListItem(
            type: .chat(chatInfo, spaceName: chatInfo.spaceId != nil ? fullSpaceViewModel.space?.name : nil),
            dialog: chat.dialog,
            lastMessage: chat.message,
            lastMessageSender: chat.from
          )
          .contentShape(Rectangle())
          .onTapGesture {
            router.push(.chat(peer: chat.peerId))
          }
        }
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

  var dialog: Dialog {
    switch self {
      case let .member(item): item.dialog
      case let .chat(item): item.dialog
    }
  }

  var hasUnread: Bool {
    (dialog.unreadCount ?? 0) > 0 || dialog.unreadMark == true
  }

  var peerId: Peer {
    switch self {
      case let .member(item): item.peerId
      case let .chat(item): item.peerId
    }
  }

  var chatId: Int64? {
    switch self {
      case let .member(item): item.chat?.id
      case let .chat(item): item.chat?.id
    }
  }
}

private extension ArchivedChatsView {
  func togglePin(_ item: SpaceCombinedItem) {
    Task {
      try await data.updateDialog(
        peerId: item.peerId,
        pinned: !item.isPinned
      )
    }
  }

  func toggleArchive(_ item: SpaceCombinedItem) {
    Task {
      try await data.updateDialog(
        peerId: item.peerId,
        archived: !(item.dialog.archived ?? false)
      )
    }
  }

  func toggleReadState(_ item: SpaceCombinedItem) {
    Task {
      do {
        if item.hasUnread {
          UnreadManager.shared.readAll(item.peerId, chatId: item.chatId ?? 0)
        } else {
          try await realtimeV2.send(.markAsUnread(peerId: item.peerId))
        }
      } catch {
        Log.shared.error("Failed to update read/unread status", error: error)
      }
    }
  }
}
