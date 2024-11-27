import GRDB
import InlineKit
import InlineUI
import SwiftUI

/// The main view of the application showing spaces and direct messages

struct MainView: View {
  // MARK: - Environment & State

  @EnvironmentObject private var nav: Navigation
  @Environment(\.appDatabase) private var database
  @Environment(\.auth) private var auth
  @EnvironmentObject private var api: ApiClient
  @EnvironmentObject private var ws: WebSocketManager
  @EnvironmentObject private var dataManager: DataManager
  @EnvironmentStateObject var root: RootData
  @EnvironmentObject private var notificationHandler: NotificationHandler

  // MARK: - View Models

  @EnvironmentStateObject private var spaceList: SpaceListViewModel
  @EnvironmentStateObject private var home: HomeViewModel

  // MARK: - State

  @State private var connection: String = ""

  var user: User? {
    root.currentUser
  }

  // MARK: - Initialization

  init() {
    _root = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: Auth.shared)
    }
    _spaceList = EnvironmentStateObject { env in
      SpaceListViewModel(db: env.appDatabase)
    }
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  // MARK: - Body

  var body: some View {
    VStack {
      contentView
    }

    .toolbar {
      toolbarContent
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()

    .task {
      notificationHandler.setAuthenticated(value: true)
      do {
        try await dataManager.getPrivateChats()

      } catch {
        Log.shared.error("Failed to getPrivateChats", error: error)
      }

      do {
        try await dataManager.getSpaces()

      } catch {
        Log.shared.error("Failed to getSpaces", error: error)
      }
    }
  }
}

// MARK: - View Components

extension MainView {
  @ViewBuilder
  fileprivate var contentView: some View {
    if spaceList.spaces.isEmpty && home.chats.isEmpty {
      // EmptyStateView()
      //   .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    } else {
      contentList
    }
  }

  fileprivate var contentList: some View {
    List {
      // HStack {
      //   Spacer()
      //   Text("Spaces Coming Soon...")
      //     .foregroundColor(.secondary)
      //     .font(.subheadline)
      //     .padding(.vertical, 6)
      //   Spacer()

      // }
      // .listRowSeparator(.hidden)
      if !home.chats.isEmpty {
        chatsSection
      }
    }
    .listStyle(.plain)
    .padding(.vertical, 8)
  }

  fileprivate var spacesSection: some View {
    Section(header: Text("Spaces")) {
      ForEach(spaceList.spaces.sorted(by: { $0.date > $1.date })) { space in
        SpaceRowView(space: space)
          .onTapGesture {
            nav.push(.space(id: space.id))
          }
      }
    }
  }

  fileprivate var chatsSection: some View {
    Section {
      ForEach(
        home.chats, id: \.user.id
      ) { chat in
        ChatRowView(item: chat)
          .onTapGesture {
            nav.push(.chat(peer: .user(id: chat.user.id)))
          }
      }
    }
  }

  fileprivate var toolbarContent: some ToolbarContent {
    Group {
      ToolbarItem(id: "UserAvatar", placement: .topBarLeading) {
        HStack {
          if let user = user {
            UserAvatar(user: user, size: 26)
              .padding(.trailing, 4)
          }
          VStack(alignment: .leading) {
            Text(user?.firstName ?? user?.lastName ?? user?.email ?? "User")
              .font(.title3)
              .fontWeight(.semibold)
            if ws.connectionState == .connecting {
              Text(connection)
                .font(.caption)
                .foregroundColor(.secondary)
                .opacity(connection.isEmpty ? 0 : 1)
                .frame(alignment: .leading)
                .onChange(of: ws.connectionState) { _, _ in
                  if ws.connectionState == .connecting {
                    connection = "Connecting..."
                  } else {
                    connection = ""
                  }
                }
                .transition(
                  .asymmetric(
                    insertion: .offset(y: 40),
                    removal: .offset(y: 40)
                  )
                  .combined(with: .opacity)
                )
            }
          }
          .animation(.smoothSnappy, value: ws.connectionState)
        }
      }

      ToolbarItem(id: "MainToolbarTrailing", placement: .topBarTrailing) {
        HStack(spacing: 2) {
          Button {
            nav.push(.settings)
          } label: {
            Image(systemName: "gearshape")
              .tint(Color.secondary)
              .frame(width: 38, height: 38)
              .contentShape(Rectangle())
          }

          Button {
            nav.push(.createDM)
          } label: {
            Image(systemName: "square.and.pencil")
              .tint(Color.secondary)
              .frame(width: 38, height: 38)
              .contentShape(Rectangle())
          }
          .padding(.top, -6)

          // Menu {
          //   Button("New DM") { nav.push(.createDM) }
          //   Button("Create Space") { nav.push(.createSpace) }
          // } label: {
          //   Image(systemName: "plus")
          //     .tint(Color.secondary)
          //     .frame(width: 38, height: 38)
          //     .contentShape(Rectangle())
          // }
        }
      }

      // ToolbarItem(id: "MainToolbarContacts", placement: .bottomBar) {
      //   ControlGroup {
      //     Button(action: {
      //       nav.push(.contacts)
      //     }) {
      //       Image(systemName: "person.3")
      //     }
      //     .buttonStyle(.plain)
      //     .contentShape(Rectangle())
      //     Button(action: {
      //       nav.push(.settings)
      //     }) {
      //       Image(systemName: "gearshape")
      //     }
      //     .buttonStyle(.plain)
      //     .contentShape(Rectangle())
      //   }

      // }
    }
  }
}

// MARK: - Helper Methods

extension MainView {
  fileprivate func handleLogout() {
    auth.logOut()
    do {
      try AppDatabase.clearDB()
    } catch {
      Log.shared.error("Failed to delete DB and logout", error: error)
    }
    nav.popToRoot()
  }
}
