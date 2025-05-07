import InlineKit
import SwiftUI

struct ChatInfoView: View {
  let chatItem: SpaceChatItem
  @StateObject private var participantsViewModel: ChatParticipantsViewModel

  var isPrivate: Bool {
    chatItem.peerId.isPrivate
  }

  var theme = ThemeManager.shared.selected

  init(chatItem: SpaceChatItem) {
    self.chatItem = chatItem
    _participantsViewModel = StateObject(wrappedValue: ChatParticipantsViewModel(
      db: AppDatabase.shared,
      chatId: chatItem.chat?.id ?? 0
    ))
  }

  var body: some View {
    List {
      if isPrivate {
        Section {
          if let userInfo = chatItem.userInfo {
            ProfileRow(userInfo: userInfo, isChatInfo: true)
          }
        }
      } else {
        Section {
          InfoRow(
            symbol: chatItem.chat?.isPublic != true ? "lock.fill" : "person.2.fill",
            color: .purple,
            title: "Chat Type",
            value: chatItem.chat?.isPublic != true ? "Private" : "Public"
          )
        }

        if chatItem.chat?.isPublic != true {
          Section("Participants") {
            ForEach(participantsViewModel.participants) { userInfo in
              ProfileRow(userInfo: userInfo, isChatInfo: true)
            }
          }
        }
      }
    }
    .navigationTitle("Chat Info")
    .listStyle(InsetGroupedListStyle())
    .onAppear {
      Task {
        await participantsViewModel.refetchParticipants()
      }
    }
  }
}
