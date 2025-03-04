import Auth
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct HomeView: View {
  // MARK: - Environment

  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var onboardingNav: OnboardingNavigation
  @EnvironmentObject private var api: ApiClient
  @EnvironmentObject private var dataManager: DataManager
  @EnvironmentObject private var notificationHandler: NotificationHandler
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @EnvironmentObject private var home: HomeViewModel
  @EnvironmentObject var data: DataManager

  @Environment(\.realtime) var realtime
  @Environment(\.appDatabase) private var database
  @Environment(\.auth) private var auth
  @Environment(\.scenePhase) var scenePhase

  // MARK: - State

  @State private var text = ""
  @State private var searchResults: [User] = []
  @State private var isSearching = false
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

  var chatItems: [HomeChatItem] {
    home.chats.filter {
      $0.dialog.archived == nil || $0.dialog.archived == false
    }.sorted { (item1: HomeChatItem, item2: HomeChatItem) in
      let pinned1 = item1.dialog.pinned ?? false
      let pinned2 = item2.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      return item1.message?.date ?? item1.chat?.date ?? Date.now > item2.message?.date ?? item2.chat?.date ?? Date.now
    }
  }

  var body: some View {
    Group {
      if !searchResults.isEmpty {
        searchResultsView
      } else if chatItems.isEmpty {
        VStack(spacing: 4) {
          Text("💬")
            .font(.system(size: 48))
            .foregroundColor(.primary)
            .padding(.bottom, 14)
          Text("No chats")
            .font(.headline)
            .foregroundColor(.primary)
          Text("Add a space or start a chat with someone to get started.")
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 45)
      } else {
        List {
          ScrollView(.horizontal) {
            LazyHStack {
              ForEach(home.spaces, id: \.id) { space in
                RectangleSpaceItem(spaceItem: space)
              }
            }
          }
          .contentMargins(.horizontal, 16, for: .scrollContent)
          .listRowInsets(.init(
            top: 0,
            leading: 0,
            bottom: 16,
            trailing: 0
          ))
          .listRowSeparator(.hidden)
          if !home.chats.filter({ $0.dialog.archived == true }).isEmpty {
            Button {
              nav.push(.archivedChats)
            } label: {
              HStack {
                Spacer()

                Text("Archived Chats")
                  .font(.callout)
                  .foregroundColor(.secondary)

                Spacer()
              }
              .frame(height: 40)
              .frame(maxWidth: .infinity)
            }
            .listRowInsets(.init(
              top: 0,
              leading: 0,
              bottom: 0,
              trailing: 0
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color(uiColor: .secondarySystemFill).opacity(0.5))
          }

          ForEach(chatItems, id: \.id) { item in
            chatView(for: item)
              .transaction { transaction in
                transaction.animation = nil
              }
              .listRowInsets(.init(
                top: 9,
                leading: 16,
                bottom: 2,
                trailing: 0
              ))
              .contextMenu {
                Button {
                  nav.push(.chat(peer: .user(id: item.user.id)))
                } label: {
                  Label("Open Chat", systemImage: "bubble.left")
                }
              } preview: {
                ChatView(peer: .user(id: item.user.id), preview: true)
                  .frame(width: Theme.shared.chatPreviewSize.width, height: Theme.shared.chatPreviewSize.height)
                  .environmentObject(nav)
                  .environmentObject(data)
                  .environment(\.realtime, realtime)
                  .environment(\.appDatabase, database)
              }
          }
        }
        .listStyle(.plain)
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()
    .toolbar {
      HomeToolbarContent()
    }
    .searchable(text: $text, prompt: "Find")
    .onChange(of: text) { _, newValue in
      searchDebouncer.input = newValue
    }
    .onReceive(searchDebouncer.$debouncedInput) { debouncedValue in
      guard let value = debouncedValue else { return }
      searchUsers(query: value)
    }
    .task {
      await initalFetch()
    }
  }

  private func searchUsers(query: String) {
    guard !query.isEmpty else {
      searchResults = []
      isSearching = false
      return
    }

    isSearching = true
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
              .fetchAll(db)
        }

        await MainActor.run {
          isSearching = false
        }
      } catch {
        Log.shared.error("Error searching users", error: error)
        await MainActor.run {
          searchResults = []
          isSearching = false
        }
      }
    }
  }

  private func initalFetch() async {
    notificationHandler.setAuthenticated(value: true)
    do {
      _ = try await dataManager.fetchMe()
    } catch {
      Log.shared.error("Failed to getMe", error: error)
      return
    }

    // Continue with existing tasks if user exists
    do {
      try await dataManager.getPrivateChats()
    } catch {
      Log.shared.error("Failed to getPrivateChats", error: error)
    }
  }

  private var searchResultsView: some View {
    List(searchResults) { user in
      HStack(spacing: 9) {
        UserAvatar(user: user, size: 38)

        VStack(alignment: .leading, spacing: 0) {
          Text((user.firstName ?? "") + " " + (user.lastName ?? ""))
            .fontWeight(.medium)
            .foregroundColor(.primary)

          Text(user.username ?? "")
            .foregroundColor(.secondary)
        }

        Spacer()
        Button {
          navigateToUser(user)
        } label: {
          Circle()
            .fill(Color(.systemGray5))
            .frame(width: 36, height: 36)
            .overlay {
              Image(systemName: "message.fill")
                .foregroundColor(ColorManager.shared.swiftUIColor)
            }
        }
      }
    }
    .listStyle(.plain)
  }

  private func navigateToUser(_ user: User) {
    Task {
      do {
        let peer = try await dataManager.createPrivateChat(userId: user.id)
        nav.push(.chat(peer: peer))
      } catch {
        Log.shared.error("Failed to create chat", error: error)
      }
    }
  }

  @ViewBuilder
  func chatView(for item: HomeChatItem) -> some View {
    if item.chat?.peerUserId != nil {
      Button {
        nav.push(.chat(peer: .user(id: item.user.id)))
      } label: {
        DirectChatItem(props: Props(
          dialog: item.dialog,
          user: item.user,
          chat: item.chat,
          message: item.message,
          from: item.from
        ))
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button(role: .destructive) {
          Task {
            try await dataManager.updateDialog(
              peerId: .user(id: item.user.id),
              archived: true
            )
          }
        } label: {
          Image(systemName: "tray.and.arrow.down.fill")
        }
        .tint(Color(.systemGray2))

        Button {
          Task {
            try await dataManager.updateDialog(
              peerId: .user(id: item.user.id),
              pinned: !(item.dialog.pinned ?? false)
            )
          }
        } label: {
          Image(systemName: item.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
        }
        .tint(.indigo)
      }
      .swipeActions(edge: .leading, allowsFullSwipe: true) {
        Button(role: .destructive) {
          Task {
            UnreadManager.shared.readAll(item.dialog.peerId, chatId: item.chat?.id ?? 0)
          }
        } label: {
          Image(systemName: "checkmark.message.fill")
        }
        .tint(.blue)
      }
    } else {
      EmptyView()
    }
  }
}

extension UIViewController {
  var topmostPresentedViewController: UIViewController {
    if let presented = presentedViewController {
      return presented.topmostPresentedViewController
    }
    return self
  }
}
