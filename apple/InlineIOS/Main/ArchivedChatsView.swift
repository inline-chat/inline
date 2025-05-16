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
    .toolbarRole(.editor)
  }

  private var homeArchivedView: some View {
    Group {
      if chatItems.isEmpty {
        EmptyArchivedView()
      } else {
        ArchivedChatsList(items: chatItems)
      }
    }
  }

  private struct EmptyArchivedView: View {
    var body: some View {
      VStack {
        Spacer()
        Image(systemName: "tray.fill")
          .foregroundColor(.secondary)
          .font(.title)
          .padding(.bottom, 6)
        Text("No archived chats")
          .font(.title3)
        Spacer()
      }
    }
  }

  private struct ArchivedChatsList: View {
    let items: [HomeChatItem]
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var data: DataManager
    @Environment(\.realtime) var realtime
    @Environment(\.appDatabase) private var database

    var body: some View {
      List {
        ForEach(items, id: \.id) { item in
          if let user = item.user {
            DirectChatRow(item: item, user: user)
          } else if let chat = item.chat {
            ThreadChatRow(item: item, chat: chat)
          }
        }
      }
      .listStyle(.plain)
      .animation(.default, value: items)
    }
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
        VStack {
          Spacer()
          Image(systemName: "tray.fill")
            .foregroundColor(.secondary)
            .font(.title)
            .padding(.bottom, 6)
          Text("No archived chats")
            .font(.title3)
          Spacer()
        }
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
        Button {
          nav.push(.chat(peer: .user(id: memberChat.user?.id ?? 0)))
        } label: {
          DirectChatItem(props: Props(
            dialog: memberChat.dialog,
            user: memberChat.userInfo,
            chat: memberChat.chat,
            message: memberChat.message,
            from: memberChat.from?.user
          ))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          Button {
            Task {
              try await data.updateDialog(
                peerId: .user(id: memberChat.user?.id ?? 0),
                archived: false
              )
            }
          } label: {
            Image(systemName: "tray.and.arrow.up.fill")
          }
          .tint(Color(.systemGray2))

          Button {
            Task {
              try await data.updateDialog(
                peerId: .user(id: memberChat.user?.id ?? 0),
                pinned: !(memberChat.dialog.pinned ?? false)
              )
            }
          } label: {
            Image(systemName: memberChat.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
          }
          .tint(.indigo)
        }
        .swipeActions(edge: .leading) {
          Button {
            Task {
              UnreadManager.shared.readAll(memberChat.dialog.peerId, chatId: memberChat.chat?.id ?? 0)
            }
          } label: {
            Image(systemName: "checkmark.message.fill")
          }
          .tint(.blue)
        }
        .contextMenu {
          Button {
            nav.push(.chat(peer: .user(id: memberChat.user?.id ?? 0)))
          } label: {
            Label("Open Chat", systemImage: "bubble.left")
          }
        } preview: {
          ChatView(peer: .user(id: memberChat.user?.id ?? 0), preview: true)
            .frame(width: Theme.shared.chatPreviewSize.width, height: Theme.shared.chatPreviewSize.height)
            .environmentObject(nav)
            .environmentObject(data)
            .environment(\.realtime, realtime)
            .environment(\.appDatabase, database)
        }

      case let .chat(chat):
        Button {
          nav.push(.chat(peer: chat.peerId))
        } label: {
          ChatItemView(props: ChatItemProps(
            dialog: chat.dialog,
            user: chat.userInfo,
            chat: chat.chat,
            message: chat.message,
            from: chat.from,
            space: chat.chat?.spaceId != nil ? fullSpaceViewModel.space : nil
          ))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          Button {
            Task {
              try await data.updateDialog(
                peerId: chat.peerId,
                archived: false
              )
            }
          } label: {
            Image(systemName: "tray.and.arrow.up.fill")
          }
          .tint(Color(.systemGray2))

          Button {
            Task {
              try await data.updateDialog(
                peerId: chat.peerId,
                pinned: !(chat.dialog.pinned ?? false)
              )
            }
          } label: {
            Image(systemName: chat.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
          }
          .tint(.indigo)
        }
        .swipeActions(edge: .leading) {
          Button {
            Task {
              UnreadManager.shared.readAll(chat.dialog.peerId, chatId: chat.chat?.id ?? 0)
            }
          } label: {
            Image(systemName: "checkmark.message.fill")
          }
          .tint(.blue)
        }
        .contextMenu {
          Button {
            nav.push(.chat(peer: chat.peerId))
          } label: {
            Label("Open Chat", systemImage: "bubble.left")
          }
        } preview: {
          ChatView(peer: chat.peerId, preview: true)
            .frame(width: Theme.shared.chatPreviewSize.width, height: Theme.shared.chatPreviewSize.height)
            .environmentObject(nav)
            .environmentObject(data)
            .environment(\.realtime, realtime)
            .environment(\.appDatabase, database)
        }
    }
  }

  private struct DirectChatRow: View {
    let item: HomeChatItem
    let user: UserInfo
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var data: DataManager
    @Environment(\.realtime) var realtime
    @Environment(\.appDatabase) private var database

    var body: some View {
      Button {
        nav.push(.chat(peer: .user(id: user.user.id)))
      } label: {
        DirectChatItem(props: Props(
          dialog: item.dialog,
          user: user,
          chat: item.chat,
          message: item.message,
          from: item.from?.user
        ))
      }
      .listRowInsets(.init(top: 9, leading: 16, bottom: 2, trailing: 0))
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button {
          Task {
            try await data.updateDialog(peerId: .user(id: user.user.id), archived: false)
          }
        } label: {
          Image(systemName: "tray.and.arrow.up.fill")
        }
        .tint(Color(.systemGray2))

        Button {
          Task {
            try await data.updateDialog(peerId: .user(id: user.user.id), pinned: !(item.dialog.pinned ?? false))
          }
        } label: {
          Image(systemName: item.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
        }
        .tint(.indigo)
      }
      .swipeActions(edge: .leading) {
        Button {
          Task {
            UnreadManager.shared.readAll(item.dialog.peerId, chatId: item.chat?.id ?? 0)
          }
        } label: {
          Image(systemName: "checkmark.message.fill")
        }
        .tint(.blue)
      }
      .contextMenu {
        Button {
          nav.push(.chat(peer: .user(id: user.user.id)))
        } label: {
          Label("Open Chat", systemImage: "bubble.left")
        }
      } preview: {
        ChatView(peer: .user(id: user.user.id), preview: true)
          .frame(width: Theme.shared.chatPreviewSize.width, height: Theme.shared.chatPreviewSize.height)
          .environmentObject(nav)
          .environmentObject(data)
          .environment(\.realtime, realtime)
          .environment(\.appDatabase, database)
      }
    }
  }

  private struct ThreadChatRow: View {
    let item: HomeChatItem
    let chat: Chat
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var data: DataManager
    @Environment(\.realtime) var realtime
    @Environment(\.appDatabase) private var database

    var body: some View {
      Button {
        nav.push(.chat(peer: .thread(id: chat.id)))
      } label: {
        ChatItemView(props: ChatItemProps(
          dialog: item.dialog,
          user: item.user,
          chat: chat,
          message: item.message,
          from: item.from,
          space: item.space
        ))
      }
      .listRowInsets(.init(top: 9, leading: 16, bottom: 2, trailing: 0))
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button {
          Task {
            try await data.updateDialog(peerId: .thread(id: chat.id), archived: false)
          }
        } label: {
          Image(systemName: "tray.and.arrow.up.fill")
        }
        .tint(Color(.systemGray2))

        Button {
          Task {
            try await data.updateDialog(peerId: .thread(id: chat.id), pinned: !(item.dialog.pinned ?? false))
          }
        } label: {
          Image(systemName: item.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
        }
        .tint(.indigo)
      }
      .swipeActions(edge: .leading) {
        Button {
          Task {
            UnreadManager.shared.readAll(item.dialog.peerId, chatId: chat.id)
          }
        } label: {
          Image(systemName: "checkmark.message.fill")
        }
        .tint(.blue)
      }
      .contextMenu {
        Button {
          nav.push(.chat(peer: .thread(id: chat.id)))
        } label: {
          Label("Open Chat", systemImage: "bubble.left")
        }
      } preview: {
        ChatView(peer: .thread(id: chat.id), preview: true)
          .frame(width: Theme.shared.chatPreviewSize.width, height: Theme.shared.chatPreviewSize.height)
          .environmentObject(nav)
          .environmentObject(data)
          .environment(\.realtime, realtime)
          .environment(\.appDatabase, database)
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
}
