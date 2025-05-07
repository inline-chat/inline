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
      if home.chats.filter({ $0.dialog.archived == true }).isEmpty {
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
          ForEach(
            home.chats.filter { $0.dialog.archived == true }.sorted { chat1, chat2 in
              chat1.message?.date ?? chat1.chat?.date ?? Date() > chat2.message?.date ?? chat2.chat?.date ?? Date()
            }
          ) { chat in
            Button {
              nav.push(.chat(peer: .user(id: chat.user.id)))
            } label: {
              DirectChatItem(props: Props(
                dialog: chat.dialog,
                user: chat.user,
                chat: chat.chat,
                message: chat.message,
                from: chat.from
              ))
            }
            .listRowInsets(.init(
              top: 9,
              leading: 16,
              bottom: 2,
              trailing: 0
            ))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
              Button {
                Task {
                  try await data.updateDialog(
                    peerId: .user(id: chat.user.id),
                    archived: false
                  )
                }
              } label: {
                Image(systemName: "tray.and.arrow.up.fill")
              }
              .tint(Color(.systemGray2))
            }
            .contextMenu {
              Button {
                nav.push(.chat(peer: .user(id: chat.user.id)))
              } label: {
                Label("Open Chat", systemImage: "bubble.left")
              }
            } preview: {
              ChatView(peer: .user(id: chat.user.id), preview: true)
                .frame(width: Theme.shared.chatPreviewSize.width, height: Theme.shared.chatPreviewSize.height)
                .environmentObject(nav)
                .environmentObject(data)
                .environment(\.realtime, realtime)
                .environment(\.appDatabase, database)
            }
          }
        }
        .listStyle(.plain)
        .animation(.default, value: home.chats)
      }
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
            from: chat.from
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
