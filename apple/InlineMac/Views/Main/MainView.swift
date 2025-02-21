import Combine
import GRDB
import InlineKit
import InlineUI
import Logger
import RealtimeAPI
import SwiftUI

struct MainView: View {
  @EnvironmentObject var window: MainWindowViewModel
  @EnvironmentObject var ws: WebSocketManager
  @EnvironmentObject var navigation: NavigationModel
  @EnvironmentObject var rootData: RootData
  @EnvironmentObject var dataManager: DataManager

  @Environment(\.requestNotifications) var requestNotifications
  @Environment(\.scenePhase) var scenePhase
  @Environment(\.realtime) var realtime

  @State private var windowSizeCancellable: AnyCancellable?
  @State private var disableAutoCollapse = false
  @State private var autoCollapsed = false

  @AppStorage("isDevtoolsOpen") var isDevtoolsOpen = false

  init() {}

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(
          min: Theme.minimumSidebarWidth,
          ideal: 240,
          max: 400
        )
    } detail: {
      VStack(spacing: 0) {
        detail
          .frame(
            minWidth: detailMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity
          ).layoutPriority(2)

        if isDevtoolsOpen {
          DevtoolsBar()
        }
      }
      .animation(.smoothSnappy, value: isDevtoolsOpen)
      .background {
        VisualEffectView(
          material: Theme.pageBackgroundMaterial,
          blendingMode: .behindWindow
        )
        .ignoresSafeArea()
      }
    }
    // Required so when sidebar is uncollapsing by user command
    // it pushed the detail view to the right instead of reducing its width
    .navigationSplitViewStyle(.prominentDetail)
    .sheet(isPresented: $navigation.createSpaceSheetPresented) {
      CreateSpaceSheet()
    }
    .environmentObject(rootData)
    .environmentObject(dataManager)
    .onAppear {
      Log.shared.info("MainView appeared • fetching root data")
      rootData.fetch()

      markAsOnline()

      fetchMe()
    }
    .task {
      await requestNotifications()
    }
    .onForeground {
      Task {
        ws.ensureConnected()
        markAsOnline()
      }
    }
    .onChange(of: scenePhase) { phase in
      if phase == .active {
        Task {
          ws.ensureConnected()
          markAsOnline()
        }

      } else if phase == .inactive {
        // Evaluate offline?
      }
    }
  }

  @ViewBuilder
  var sidebar: some View {
    let sidebar = Group {
      if let spaceId = navigation.activeSpaceId {
        SpaceSidebar(spaceId: spaceId)
      } else {
        HomeSidebar()
      }
    }

    if #available(macOS 14.0, *) {
      sidebar.toolbar(removing: .sidebarToggle)
    } else {
      sidebar
    }
  }

  var detail: some View {
    NavigationStack(path: path) {
      if let spaceId = navigation.activeSpaceId {
        renderSpaceRoute(for: navigation.spaceSelection.wrappedValue, spaceId: spaceId)
          .id(navigation.spaceSelection.wrappedValue)
          .navigationDestination(for: NavigationRoute.self) { route in
            renderSpaceRoute(for: route, spaceId: spaceId)
          }

      } else {
        renderHomeRoute(for: navigation.homeSelection)
          // Note(@mo): without this .id, route would not update correctly
          .id(navigation.homeSelection)
          .navigationDestination(for: NavigationRoute.self) { route in
            renderHomeRoute(for: route)
          }
      }
    }
  }

  var path: Binding<[NavigationRoute]> {
    if let _ = navigation.activeSpaceId {
      navigation.spacePath
    } else {
      $navigation.homePath
    }
  }

  @ViewBuilder
  func renderSpaceRoute(for destination: NavigationRoute, spaceId: Int64) -> some View {
    switch destination {
      case .spaceRoot:
        SpaceView(spaceId: spaceId)

      case let .chat(peer):
        ChatView(peerId: peer)

      case let .chatInfo(peer):
        ChatInfo(peerId: peer)

      case .homeRoot:
        // Not for space
        HomeRoot()

      case let .profile(userInfo):
        UserProfile(userInfo: userInfo)
    }
  }

  @ViewBuilder
  func renderHomeRoute(for destination: NavigationRoute) -> some View {
    switch destination {
      case let .chat(peer):
        ChatView(peerId: peer)

      case .homeRoot:
        HomeRoot()

      case let .chatInfo(peer):
        ChatInfo(peerId: peer)

      case let .profile(userInfo):
        UserProfile(userInfo: userInfo)

      case .spaceRoot:
        // Not for home
        Text("")
    }
  }

  // MARK: - Sidebar Auto Collapse

  // This difference makes collapse/uncollapse more satisfying as it doesn't lock in place when uncollapsing at minimum
  // width
  var detailMinWidth: CGFloat {
    // This was used for auto column collapse
//    if window.columnVisibility == .detailOnly {
//      400
//    } else {
//      200
//    }
    Theme.chatViewMinWidth
  }

  private func markAsOnline() {
    Task {
      try? await dataManager.updateStatus(online: true)
    }
  }

  private func fetchMe() {
    Task {
      do {
        let result = try await realtime.invoke(.getMe, input: .getMe(.init()))
        Log.shared.debug("Fetched me \(result)")
      } catch let RealtimeAPIError.rpcError(errorCode, message) {
        Log.shared.error("Failed to fetch me \(errorCode) \(message)")
      }
    }
  }
}

#Preview {
  MainView()
    .previewsEnvironmentForMac(.empty)
}
