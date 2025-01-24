import InlineKit
import SwiftUI

struct ArchivedChatsView: View {
  @EnvironmentObject private var home: HomeViewModel
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var dataManager: DataManager

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
            }) { chat in
              Button {
                nav.push(.chat(peer: .user(id: chat.user.id)))
              } label: {
                ChatRowView(item: .home(chat))
              }
              .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                  Task {
                    try await dataManager.updateDialog(
                      peerId: .user(id: chat.user.id),
                      archived: false)
                  }
                } label: {
                  Image(systemName: "tray.and.arrow.up.fill")
                }
                .tint(Color(.systemGray2))
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
