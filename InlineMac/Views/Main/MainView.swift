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

  @State private var windowSizeCancellable: AnyCancellable?
  @State private var disableAutoCollapse = false
  @State private var autoCollapsed = false
  
  init() {}
  
  var body: some View {
    NavigationSplitView(columnVisibility: $window.columnVisibility) {
      sidebar
    } detail: {
      detail
        .frame(minWidth: detailMinWidth)
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
      self.rootData.fetch()
      self.setUpSidebarAutoCollapse()
    }
    .task {
      await requestNotifications();
    }
    // Disable auto collapse while user is modifying it to avoid jump
    .onChange(of: window.columnVisibility) { _ in
      disableAutoCollapse = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        disableAutoCollapse = false
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
      return navigation.spacePath
    } else {
      return $navigation.homePath
    }
  }
  
  @ViewBuilder
  func renderSpaceRoute(for destination: NavigationRoute, spaceId: Int64) -> some View {
    switch destination {
    case .spaceRoot:
      SpaceView(spaceId: spaceId)
        
    case .chat(let peer):
      ChatView(peerId: peer)
    
    case .chatInfo(let peer):
      ChatInfo(peerId: peer)
        
    case .homeRoot:
      // Not for space
      HomeRoot()
    }
  }
  
  @ViewBuilder
  func renderHomeRoute(for destination: NavigationRoute) -> some View {
    switch destination {
    case .chat(let peer):
      ChatView(peerId: peer)
        
    case .homeRoot:
      HomeRoot()
      
    case .chatInfo(let peer):
      ChatInfo(peerId: peer)
        
    case .spaceRoot:
      // Not for home
      Text("")
    }
  }
  
  // MARK: - Sidebar Auto Collapse

  // This difference makes collapse/uncollapse more satisfying as it doesn't lock in place when uncollapsing at minimum width
  var detailMinWidth: CGFloat {
    if window.columnVisibility == .detailOnly {
      400
    } else {
      200
    }
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
            if autoCollapsed && window.columnVisibility == .detailOnly {
              window.columnVisibility = .automatic
              autoCollapsed = false
            }
          }
        }
    }
  }
}

#Preview {
  MainView()
    .previewsEnvironmentForMac(.empty)
}
