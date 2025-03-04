import InlineKit
import SwiftUI

struct ArchivedChatsView: View {
  @EnvironmentObject private var home: HomeViewModel
  @EnvironmentObject private var nav: Navigation

  @EnvironmentObject var data: DataManager
  @Environment(\.realtime) var realtime
  @Environment(\.appDatabase) private var database

  var body: some View {
    Group {
      if home.chats.filter { $0.dialog.archived == true }.isEmpty {
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
              chat1.message?.date ?? chat1.chat?.date ?? Date() > chat2.message?.date ?? chat2.chat?.date
                ?? Date()
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
              Button(role: .destructive) {
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
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(id: "UserAvatar", placement: .principal) {
        HStack {
          Image(systemName: "tray.full.fill")
            .foregroundColor(.secondary)
            .font(.callout)
            .padding(.trailing, 4)
          VStack(alignment: .leading) {
            Text("Archived Chats")
              .font(.body)
              .fontWeight(.semibold)
          }
        }
      }
    }
  }
}
