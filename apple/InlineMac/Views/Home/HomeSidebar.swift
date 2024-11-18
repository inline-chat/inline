import InlineKit
import SwiftUI

struct HomeSidebar: View {
  @EnvironmentObject var ws: WebSocketManager
  @EnvironmentObject var nav: NavigationModel
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var overlay: OverlayManager
  @Environment(\.appDatabase) var db

  @EnvironmentStateObject var model: SpaceListViewModel
  @EnvironmentStateObject var home: HomeViewModel

  @StateObject var search = GlobalSearch()
  @FocusState private var isSearching: Bool

  init() {
    _model = EnvironmentStateObject { env in
      SpaceListViewModel(db: env.appDatabase)
    }
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  var body: some View {
    List {
      if search.hasResults || (isSearching && search.canSearch) {
        searchView
      } else {
        spacesAndUsersView
      }
    }
    .toolbar(content: {
      ToolbarItem(placement: .automatic) {
        Menu("New", systemImage: "plus") {
          Button("New Space") {
            nav.createSpaceSheetPresented = true
          }
        }
      }
    })
    .listStyle(.sidebar)
    .safeAreaInset(
      edge: .top,
      content: {
        VStack(alignment: .leading) {
          SelfUser()
          searchBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
      }
    )
    .overlay(
      alignment: .bottom,
      content: {
        ConnectionStateOverlay()
      }
    )
    .task {
      do {
        let _ = try await data.getSpaces()
      } catch {
        // TODO: handle error? keep on loading? retry? (@mo)
      }
    }
  }

  var searchBar: some View {
    SidebarSearchBar(text: $search.query)
      .focused($isSearching)
      .onChange(of: search.query) { _ in
        search.search()
      }
      .background {
        KeyPressHandler {
          if isSearching {
            if $0.keyCode == 53 { // ESC key code
              search.clear()
              isSearching = false
              return nil
            }
          }

          return $0
        }
      }
  }

  @ViewBuilder
  var spacesAndUsersView: some View {
    Section("Spaces") {
      ForEach(model.spaces) { space in
        SpaceItem(space: space)
          .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
      }
    }
    
    Section("Private Messages") {
      ForEach(home.chats) { chat in
        UserItem(user: chat.user, action: {
          userPressed(user: chat.user)
        })
          .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
      }
    }
  }

  // The view when user focuses the search input shows up
  @ViewBuilder
  var searchView: some View {
    if search.hasResults {
      Section("Users") {
        ForEach(search.results, id: \.self) { result in
          switch result {
          case .users(let user):
            RemoteUserItem(user: user, action: {
              remoteUserPressed(user: user)
            })
            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
          }
        }
      }
    } else {
      HStack {
        if search.isLoading {
          Text("Searching...")
        } else if let error = search.error {
          Text("Failed to load: \(error.localizedDescription)")
        } else if !search.query.isEmpty {
          // User searched, loading is done, but we didn't find a result
          Text("No user found.")
        } else {
          Text("Search by username to start a chat.")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .lineLimit(2)
      .font(.body)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding()
    }
  }

  private func remoteUserPressed(user: ApiUser) {
    // Save user

    Task { @MainActor in
      do {
        try await data.createPrivateChatWithOptimistic(user: user)

        // Clear search
        search.clear()
        isSearching = false

        nav.navigate(to: .chat(peer: .user(id: user.id)))
      } catch {
        overlay.showError(message: "Failed to open a private chat with \(user.anyName)")
      }
    }
  }
  
  private func userPressed(user: User) {
    // Open chat in home
    nav.navigate(to: .chat(peer: .user(id: user.id)))
  }
}

struct ConnectionStateOverlay: View {
  @EnvironmentObject var ws: WebSocketManager
  @State var show = false

  var body: some View {
    Group {
      if show {
        capsule
      }
    }.task {
      if ws.connectionState != .normal {
        show = true
      }
    }
    .onChange(of: ws.connectionState) { newValue in
      if newValue == .normal {
        Task { @MainActor in
          try await Task.sleep(for: .seconds(1))
          if ws.connectionState == .normal {
            // second check
            show = false
          }
        }
      } else {
        show = true
      }
    }
  }

  var capsule: some View {
    HStack {
      Text(textContent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
    .frame(maxWidth: .infinity)
    .background(.ultraThinMaterial)
    .clipShape(.capsule(style: .continuous))
    .padding()
  }

  private var textContent: String {
    switch ws.connectionState {
    case .normal:
      return "connected"
    case .connecting:
      return "connecting..."
    case .updating:
      return "updating..."
    }
  }
}

#Preview {
  NavigationSplitView {
    HomeSidebar()
      .previewsEnvironment(.populated)
      .environmentObject(NavigationModel())
  } detail: {
    Text("Welcome.")
  }
}
