import Combine
import GRDB
import InlineKit
import InlineUI
import SwiftUI

struct MainView: View {
  @EnvironmentObject var window: MainWindowViewModel
  @EnvironmentObject var ws: WebSocketManager
  @EnvironmentObject var navigation: NavigationModel
  @EnvironmentObject var rootData: RootData
  @EnvironmentObject var dataManager: DataManager

  @Environment(\.requestNotifications) var requestNotifications
  @Environment(\.scenePhase) var scenePhase

  @State private var windowSizeCancellable: AnyCancellable?
  @State private var disableAutoCollapse = false
  @State private var autoCollapsed = false

  @AppStorage("isDevtoolsOpen") var isDevtoolsOpen = false

  init() {}

  var body: some View {
    NavigationSplitView(columnVisibility: $window.columnVisibility) {
      sidebar
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
      }.animation(.smoothSnappy, value: isDevtoolsOpen)
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
      setUpSidebarAutoCollapse()

      markAsOnline()
    }
    .task {
      await requestNotifications()
    }
    // Disable auto collapse while user is modifying it to avoid jump
    .onChange(of: window.columnVisibility) { _ in
      disableAutoCollapse = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        disableAutoCollapse = false
      }
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
    Group {
      if let spaceId = navigation.activeSpaceId {
        SpaceSidebar(spaceId: spaceId)
      } else {
        HomeSidebar()
      }
    }.navigationSplitViewColumnWidth(
      min: Theme.minimumSidebarWidth,
      ideal: 240,
      max: 400
    )
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

  private func setUpSidebarAutoCollapse() {
    Task { @MainActor in
      // delay
      try await Task.sleep(for: .milliseconds(300))
      // Listen to window size for collapsing sidebar
      windowSizeCancellable = window.windowSize
        .sink { size in
          // Prevent conflict with default animation when user is uncollapsing the sidebar
          if disableAutoCollapse { return }
          if size.width < Theme.collapseSidebarAtWindowSize {
            if window.columnVisibility != .detailOnly {
              window.columnVisibility = .detailOnly
              autoCollapsed = true
            }
          } else {
            if autoCollapsed, window.columnVisibility == .detailOnly {
              window.columnVisibility = .automatic
              autoCollapsed = false
            }
          }
        }
    }
  }

  private func markAsOnline() {
    Task {
      try? await dataManager.updateStatus(online: true)
    }
  }
}

#Preview {
  MainView()
    .previewsEnvironmentForMac(.empty)
}
