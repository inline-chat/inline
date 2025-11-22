import AppKit
import InlineKit
import SwiftUI

struct MainSidebarView: View {
  @State private var isBeyondZero: Bool = false

  @Environment(\.appDatabase) var db
  @EnvironmentObject var nav: Nav
  @EnvironmentStateObject var home: HomeViewModel

  init() {
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  private var items: [HomeChatItem] {
    home.myChats.filter { item in
      // Only DMs
      item.user != nil
    }
  }

  var body: some View {
    VStack(spacing: 8) {
      Text("Direct Messages")
        .foregroundStyle(.tertiary)
        .font(.system(size: 12, weight: .regular))
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)

      List {
        ForEach(items) { item in
          MainSidebarItem(
            type: itemType(for: item),
            dialog: item.dialog,
            lastMessage: item.lastMessage?.message,
            lastMessageSender: item.lastMessage?.senderInfo,
            selected: isSelected(item),
            onPress: {
              handleItemPress(item)
            }
          )
          .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
          .listRowSeparator(.hidden)
        }
      }
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y > 0
      } action: { _, isBeyondZero in
        self.isBeyondZero = isBeyondZero
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .padding(.all, 0)
      .safeAreaPadding(.all, 0)
      .clipShape(Rectangle())
      .frame(maxWidth: .infinity)
      .overlay(alignment: .top) {
        if isBeyondZero {
          Rectangle()
            .fill(.quinary)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private func itemType(for item: HomeChatItem) -> MainSidebarItem.SidebarItemType {
    if let user = item.user {
      .user(user, chat: item.chat)
    } else if let chat = item.chat {
      .chat(chat)
    } else {
      fatalError("HomeChatItem must have either chat or user")
    }
  }

  private func isSelected(_ item: HomeChatItem) -> Bool {
    nav.currentRoute == .chat(peer: item.peerId)
  }

  private func handleItemPress(_ item: HomeChatItem) {
    nav.open(.chat(peer: item.peerId))
  }
}
