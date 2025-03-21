import InlineKit
import Logger
import SwiftUI

struct HomeSidebar: View {
  @EnvironmentObject var nav: Nav
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

  fileprivate var items: [SideItem] {
    var items: [SideItem] = []

    items.append(contentsOf: model.fullSpaces.map { .space($0) })
    items.append(contentsOf: home.chats.map { .user($0) })

    return items
  }

  var body: some View {
    List {
      if search.hasResults || (isSearching && search.canSearch) {
        searchView
      } else {
        spacesAndUsersView
      }
    }
//    .toolbar(content: {
//      ToolbarItemGroup(placement: .automatic) {
//        Spacer()
//
//        Menu("New", systemImage: "plus") {
//          Button("New Space") {
//            nav.createSpaceSheetPresented = true
//          }
//        }
//      }
//    })
    .listStyle(.sidebar)
    .safeAreaInset(
      edge: .top,
      content: {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .center, spacing: 0) {
            SelfUser()

            AlphaCapsule()
          }
          .padding(.top, 0)
          .padding(.bottom, 8)

          searchBar
            .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal) // default side padding
        .padding(.leading, Theme.sidebarItemLeadingGutter) // gutter to sync with items
        
      }
    )
  }

  var searchBar: some View {
    SidebarSearchBar(text: $search.query)
      .focused($isSearching)
      .onChange(of: search.query) { _ in
        search.search()
      }
      .background {
        KeyPressHandler {
          if $0.keyCode == 53 { // ESC key code
            if isSearching {
              search.clear()
              isSearching = false
            } else {
              // Navigate to home root and clear selection
              nav.handleEsc()
            }
            return nil
          }

          return $0
        }
      }
  }

  @ViewBuilder
  var spacesAndUsersView: some View {
    ForEach(items) { item in
      renderItem(item)
    }
  }

  @ViewBuilder
  fileprivate func renderItem(_ item: SideItem) -> some View {
    switch item {
      case let .user(chat):
        userItem(chat: chat)

      case let .space(space):
        SpaceItem(space: space)
          .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
  }

  @ViewBuilder
  func userItem(chat: HomeChatItem) -> some View {
    let userInfo = chat.user
    let user = userInfo.user
    let dialog = chat.dialog
    let chatChat = chat.chat

    UserItem(
      userInfo: userInfo,
      dialog: dialog,
      chat: chatChat,
      action: {
        userPressed(user: user)
      },
      commandPress: {
        openInWindow(Peer.user(id: user.id))
      },
      // selected: nav.currentRoute == .chat(peer: .user(id: user.id)),
      selected: nav.upcomingRoute == .chat(peer: .user(id: user.id)),
      rendersSavedMsg: true
    )
    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
  }

  // The view when user focuses the search input shows up
  @ViewBuilder
  var searchView: some View {
    if search.hasResults {
      Section("Users") {
        ForEach(search.results, id: \.self) { result in
          switch result {
            case let .users(user):
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

        nav.open(.chat(peer: .user(id: user.id)))
      } catch {
        Log.shared.error("Failed to open a private chat with \(user.anyName)", error: error)
        overlay.showError(message: "Failed to open a private chat with \(user.anyName)")
      }
    }
  }

  private func userPressed(user: User) {
    // Open chat in home
    nav.open(.chat(peer: .user(id: user.id)))
  }

  private func openInWindow(_ peer: Peer) {
    // TODO: implement when we support multiple windows
    nav.open(.chat(peer: peer))
  }
}

private enum SideItem: Identifiable {
  case space(InlineKit.Space)
  case user(InlineKit.HomeChatItem)

  var id: Int64 {
    switch self {
      case let .space(space):
        space.id
      case let .user(chat):
        chat.user.id
    }
  }
}

struct AlphaCapsule: View {
  @State private var showingSheet = false

  var body: some View {
    Text("ALPHA")
      .monospaced()
      .foregroundStyle(.primary)
      .font(.caption)
      .fontWeight(.semibold)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(
        Capsule()
          .strokeBorder(.primary, lineWidth: 1.0)
      )
      .opacity(0.5)
      .onTapGesture {
        showingSheet = true
      }
      .sheet(isPresented: $showingSheet) {
        AlphaInfoSheet()
      }
  }
}

struct AlphaInfoSheet: View {
  @Environment(\.dismiss) private var dismiss
  @AppStorage("alphaText") private var text: String = ""

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Text(.init(text))
          .font(.body)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 320)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .task {
        do {
          text = try await ApiClient.shared.getAlphaText()
        } catch {}
      }
    }
    .presentationDetents([.medium])
  }
}

#Preview {
  NavigationSplitView {
    HomeSidebar()
      .previewsEnvironmentForMac(.populated)
  } detail: {
    Text("Welcome.")
  }
}
