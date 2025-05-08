import Auth
import Foundation
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SearchUserRow: View {
  let userInfo: UserInfo
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 9) {
        UserAvatar(userInfo: userInfo, size: 32)
        Text((userInfo.user.firstName ?? "") + " " + (userInfo.user.lastName ?? ""))
          .fontWeight(.medium)
          .foregroundColor(.primary)
      }
    }
  }
}

struct EmptySearchView: View {
  let isSearching: Bool

  var body: some View {
    if isSearching {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 4) {
        Text("🔍")
          .font(.largeTitle)
          .foregroundColor(.primary)
          .padding(.bottom, 14)
        Text("Search for people")
          .font(.headline)
          .foregroundColor(.primary)
        Text("Type a username to find someone to add. eg. dena, mo")
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 45)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct ChatInfoView: View {
  let chatItem: SpaceChatItem
  @StateObject private var participantsViewModel: ChatParticipantsViewModel
  @EnvironmentStateObject private var spaceMembersViewModel: SpaceMembersViewModel
  @State private var isSearching = false
  @State private var searchText = ""
  @State private var searchResults: [UserInfo] = []
  @State private var isSearchingState = false
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var api: ApiClient

  @Environment(\.appDatabase) private var database

  var isPrivate: Bool {
    chatItem.peerId.isPrivate
  }

  var theme = ThemeManager.shared.selected

  var currentMemberRole: MemberRole? {
    spaceMembersViewModel.members.first(where: { $0.userId == Auth.shared.getCurrentUserId() })?.role
  }

  var isOwnerOrAdmin: Bool {
    currentMemberRole == .owner || currentMemberRole == .admin
  }

  init(chatItem: SpaceChatItem) {
    self.chatItem = chatItem
    _participantsViewModel = StateObject(wrappedValue: ChatParticipantsViewModel(
      db: AppDatabase.shared,
      chatId: chatItem.chat?.id ?? 0
    ))

    _spaceMembersViewModel = EnvironmentStateObject { env in
      SpaceMembersViewModel(db: env.appDatabase, spaceId: chatItem.chat?.spaceId ?? 0)
    }
  }

  private func searchUsers(query: String) {
    guard !query.isEmpty else {
      searchResults = []
      isSearchingState = false
      return
    }

    isSearchingState = true
    Task {
      do {
        let result = try await api.searchContacts(query: query)

        try await database.dbWriter.write { db in
          for apiUser in result.users {
            try apiUser.saveFull(db)
          }
        }

        try await database.reader.read { db in
          searchResults =
            try User
              .filter(Column("username").like("%\(query.lowercased())%"))
              .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
              .asRequest(of: UserInfo.self)
              .fetchAll(db)
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

  private func addParticipant(_ userInfo: UserInfo) {
    Task {
      do {
        try await Realtime.shared.invokeWithHandler(
          .addChatParticipant,
          input: .addChatParticipant(.with { input in
            input.chatID = chatItem.chat?.id ?? 0
            input.userID = userInfo.user.id
          })
        )
        isSearching = false
        searchText = ""
      } catch {
        Log.shared.error("Failed to add participant", error: error)
      }
    }
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

        Section("Participants") {
          if isOwnerOrAdmin {
            Button(action: {
              isSearching = true
            }) {
              Label("Add Participant", systemImage: "person.badge.plus")
            }
          }
          ForEach(participantsViewModel.participants) { userInfo in
            ProfileRow(userInfo: userInfo, isChatInfo: true)
              .swipeActions {
                if isOwnerOrAdmin {
                  Button(role: .destructive, action: {
                    Task {
                      do {
                        try await Realtime.shared.invokeWithHandler(.removeChatParticipant, input: .removeChatParticipant(.with { input in
                          input.chatID = chatItem.chat?.id ?? 0
                          input.userID = userInfo.user.id
                        }))
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
    }
    .navigationTitle("Chat Info")
    .listStyle(InsetGroupedListStyle())
    .onAppear {
      Task {
        if let spaceId = chatItem.chat?.spaceId {
          await spaceMembersViewModel.refetchMembers()
        }
        await participantsViewModel.refetchParticipants()
      }
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("chatDeletedNotification"))
    ) { notification in
      if let chatId = notification.userInfo?["chatId"] as? Int64,
         chatId == chatItem.chat?.id
      {
        nav.pop()
      }
    }
    .sheet(isPresented: $isSearching) {
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
}

struct SearchParticipantsView: View {
  @Binding var searchText: String
  let searchResults: [UserInfo]
  let isSearching: Bool
  let onSearchTextChanged: (String) -> Void
  let onDebouncedInput: (String?) -> Void
  let onAddParticipant: (UserInfo) -> Void
  let onCancel: () -> Void
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

  var body: some View {
    NavigationView {
      VStack {
        if !searchResults.isEmpty {
          List {
            ForEach(searchResults) { userInfo in
              Button(action: { onAddParticipant(userInfo) }) {
                HStack(spacing: 9) {
                  UserAvatar(userInfo: userInfo, size: 32)
                  Text((userInfo.user.firstName ?? "") + " " + (userInfo.user.lastName ?? ""))
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                }
              }
            }
          }
        } else {
          if isSearching {
            VStack {
              ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          } else {
            VStack(spacing: 4) {
              Text("🔍")
                .font(.largeTitle)
                .foregroundColor(.primary)
                .padding(.bottom, 14)
              Text("Search for people")
                .font(.headline)
                .foregroundColor(.primary)
              Text("Type a username to find someone to add. eg. dena, mo")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 45)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
      .searchable(text: $searchText, prompt: "Find")
      .onChange(of: searchText) { _, newValue in
        searchDebouncer.input = newValue
      }
      .onReceive(searchDebouncer.$debouncedInput) { debouncedValue in
        onDebouncedInput(debouncedValue)
      }
      .navigationTitle("Add Participant")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            onCancel()
          }
        }
      }
    }
  }
}
