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
  @EnvironmentStateObject var root: RootData

  // MARK: - View Models

  @EnvironmentStateObject private var dataManager: DataManager
  @EnvironmentStateObject private var spaceList: SpaceListViewModel
  @EnvironmentStateObject private var home: HomeViewModel

  // MARK: - State

  @State private var showSheet = false
  @State private var showDmSheet = false
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
    _dataManager = EnvironmentStateObject { env in
      DataManager(database: env.appDatabase)
    }
  }

  // MARK: - Body

  var body: some View {
    VStack {
      contentView
    }
    .toolbar { toolbarContent }
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()
    .sheet(isPresented: $showSheet) {
      CreateSpace(showSheet: $showSheet)
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(28)
    }
    .sheet(isPresented: $showDmSheet) {
      CreateDm(showSheet: $showDmSheet)
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(28)
    }
    .task {
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
      EmptyStateView(showDmSheet: $showDmSheet, showSheet: $showSheet)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    } else {
      contentList
    }
  }

  fileprivate var contentList: some View {
    List {
      if !spaceList.spaces.isEmpty {
        spacesSection
      }

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
    Section(header: Text("Direct Messages")) {
      ForEach(home.chats.sorted(by: { $0.chat.date > $1.chat.date }), id: \.chat.id) { chat in
        ChatRowView(item: chat)
          .onTapGesture {
            if let id = chat.user?.id {
              nav.push(.chat(peer: .user(id: id)))
            }
          }
      }
    }
  }

  fileprivate var toolbarContent: some ToolbarContent {
    Group {
      ToolbarItem(placement: .topBarLeading) {
        HStack {
          if let user = user {
            UserAvatar(user: user, size: 26)
              .padding(.trailing, 4)
          }
          VStack(alignment: .leading) {
            Text(user?.firstName ?? user?.lastName ?? user?.email ?? "User")
              .font(.title3)
              .fontWeight(.semibold)
            if ws.connectionState != .normal {
              Text(connection)
                .font(.caption)
                .foregroundColor(.secondary)
                .opacity(connection.isEmpty ? 0 : 1)
                .frame(alignment: .leading)
                .onChange(of: ws.connectionState) { _, _ in
                  if ws.connectionState == .normal {
                    connection = ""
                  } else if ws.connectionState == .connecting {
                    connection = "Connecting..."
                  } else if ws.connectionState == .updating {
                    connection = "Updating..."
                  }
                }
            }
          }
        }
        //                }
      }

      ToolbarItem(placement: .topBarTrailing) {
        HStack(spacing: 4) {
          Menu {
            Button("New DM") { showDmSheet = true }
            Button("Create Space") { showSheet = true }

          } label: {
            Image(systemName: "ellipsis")
              .tint(Color.secondary)
              .frame(width: 38, height: 38)
              .contentShape(Rectangle())
          }
          Button(action: {
            nav.push(.settings)
          }) {
            Image(systemName: "gearshape")
              .tint(Color.secondary)
              .frame(width: 38, height: 38)
              .contentShape(Rectangle())
          }
        }
      }
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
