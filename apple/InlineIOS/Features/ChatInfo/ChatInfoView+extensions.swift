import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

extension ChatInfoView {
  func searchUsers(query: String) {
    guard !query.isEmpty else {
      searchResults = []
      isSearchingState = false
      return
    }

    isSearchingState = true
    Task {
      do {
        try await database.reader.read { db in
          searchResults =
            try User
              .filter(
                sql: "username LIKE ? OR firstName LIKE ? OR lastName LIKE ?",
                arguments: [
                  "%\(query.lowercased())%",
                  "%\(query.lowercased())%",
                  "%\(query.lowercased())%",
                ]
              )
              // .filter(
              //   Column("username").like("%\(query.lowercased())%")
              // )
              // .filter(Column("firstName").like("%\(query.lowercased())%"))
              // .filter(Column("lastName").like("%\(query.lowercased())%"))
              .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
              .asRequest(of: UserInfo.self)
              .fetchAll(db)
          print("searchResults: \(searchResults)")
        }

        await MainActor.run {
          isSearchingState = false
        }
      } catch {
        Log.shared.error("Error searching users", error: error)
        await MainActor.run {
          searchResults = []
          isSearchingState = false
        }
      }
    }
  }

  func addParticipant(_ userInfo: UserInfo) {
    guard currentChatId != 0 else {
      Log.shared.error("No chat ID found when trying to add participant")
      return
    }
    Task {
      do {
        try await Api.realtime.send(.addChatParticipant(
          chatID: currentChatId,
          userID: userInfo.user.id
        ))
        isSearching = false
        searchText = ""
      } catch {
        Log.shared.error("Failed to add participant", error: error)
      }
    }
  }

  func showMessageInChat(_ message: Message) {
    router.selectedTab = .chats
    router.pop(for: .chats)

    if !nav.pathComponents.isEmpty {
      nav.pop()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      NotificationCenter.default.post(
        name: Notification.Name("ScrollToRepliedMessage"),
        object: nil,
        userInfo: [
          "repliedToMessageId": message.messageId,
          "chatId": message.chatId,
        ]
      )
    }
  }

  func formatSectionDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return "Today"
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: date)
    } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMM d"
      return formatter.string(from: date)
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMM d, yyyy"
      return formatter.string(from: date)
    }
  }

  @ViewBuilder
  var chatInfoHeader: some View {
    VStack {
      if isDM, let userInfo = chatItem.userInfo {
        ParticipantAvatarView(userInfo: userInfo, size: 82)
          .frame(width: 82, height: 82)
        VStack(spacing: -3) {
          Text(userInfo.user.firstName ?? "User")
            .font(.title2)
            .fontWeight(.semibold)
          if let username = userInfo.user.username {
            Text("@\(username)")
              .font(.callout)
              .foregroundColor(.secondary)
          } else {
            Text(userInfo.user.firstName ?? "user")
              .font(.callout)
              .foregroundColor(.secondary)
          }
        }
      } else {
        Circle()
          .fill(
            LinearGradient(
              colors: chatProfileColors,
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .overlay {
            Group {
              if let emoji = currentChat?.emoji {
                Text(
                  String(describing: emoji).replacingOccurrences(of: "Optional(\"", with: "")
                    .replacingOccurrences(of: "\")", with: "")
                )
                .font(.system(size: 40))
              } else {
                Text("💬")
                  .font(.system(size: 40))
              }
            }
          }
          .frame(width: 100, height: 100)

        Text(chatTitle)
          .font(.title2)
          .fontWeight(.semibold)
      }
    }
  }

  @ViewBuilder
  var chatInfoContent: some View {
    if isPrivate {
      privateChatSection

    } else {
      publicChatSection
    }

    if !documentsViewModel.documentMessages.isEmpty {
      documentsSection
    }
  }

  @ViewBuilder
  var privateChatSection: some View {
    Section {
      if let userInfo = chatItem.userInfo {
        ProfileRow(userInfo: userInfo, isChatInfo: true)
      }
    }
  }

  @ViewBuilder
  var publicChatSection: some View {
    Section {
      Label("Type", systemImage: currentChat?.isPublic != true ? "lock.fill" : "person.2.fill")

      Spacer()

      Text(currentChat?.isPublic != true ? "Private" : "Public")
    }

    if currentChat?.isPublic != true {
      participantsSection
    }
  }

  @ViewBuilder
  var participantsSection: some View {
    Section("Participants") {
      if isOwnerOrAdmin, isPrivate {
        Button(action: {
          isSearching = true
        }) {
          Label("Add Participant", systemImage: "person.badge.plus")
        }
      }
      ForEach(participantsWithMembersViewModel.participants) { userInfo in
        ProfileRow(userInfo: userInfo, isChatInfo: true)
          .swipeActions {
            if isOwnerOrAdmin, isPrivate {
              Button(role: .destructive, action: {
                guard currentChatId != 0 else {
                  Log.shared.error("No chat ID found when trying to remove participant")
                  return
                }
                Task {
                  do {
                    try await Api.realtime.send(.removeChatParticipant(
                      chatID: currentChatId,
                      userID: userInfo.user.id
                    ))
                  } catch {
                    Log.shared.error("Failed to remove participant", error: error)
                  }
                }
              }) {
                Text("Remove")
              }
            }
          }
      }
    }
  }

  @ViewBuilder
  var documentsSection: some View {
    ForEach(documentsViewModel.documentMessages, id: \.id) { documentMessage in
      DocumentRow(
        documentMessage: documentMessage,
        chatId: currentChatId == 0 ? nil : currentChatId
      )
    }
  }

  private func createFullMessage(from documentInfo: DocumentInfo) -> FullMessage? {
    let message = Message(
      messageId: documentInfo.document.documentId,
      fromId: 1,
      date: documentInfo.document.date,
      text: nil,
      peerUserId: nil,
      peerThreadId: currentChatId == 0 ? nil : currentChatId,
      chatId: currentChatId,
      documentId: documentInfo.document.id
    )

    return FullMessage(
      senderInfo: nil,
      message: message,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }

  @ViewBuilder
  var searchSheet: some View {
    SearchParticipantsView(
      searchText: $searchText,
      searchResults: searchResults,
      isSearching: isSearchingState,
      onSearchTextChanged: { text in
        searchDebouncer.input = text
      },
      onDebouncedInput: { value in
        guard let value else { return }
        searchUsers(query: value)
      },
      onAddParticipant: addParticipant,
      onCancel: {
        isSearching = false
        searchText = ""
      }
    )
  }
}
