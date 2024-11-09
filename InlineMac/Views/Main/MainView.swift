import GRDB
import InlineKit
import InlineUI
import SwiftUI

struct MainView: View {
  @EnvironmentObject var windowViewModel: MainWindowViewModel
  @EnvironmentObject var ws: WebSocketManager
  @EnvironmentObject var navigation: NavigationModel

  // Fetch authenticated user data
  @EnvironmentStateObject var rootData: RootData
  @EnvironmentStateObject var dataManager: DataManager

  init() {
    _rootData = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: env.auth)
    }
    _dataManager = EnvironmentStateObject { env in
      DataManager(database: env.appDatabase)
    }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $windowViewModel.columnVisibility) {
      sidebar
    } detail: {
      detail
    }
    .sheet(isPresented: $navigation.createSpaceSheetPresented) {
      CreateSpaceSheet()
    }
    .environmentObject(rootData)
    .environmentObject(dataManager)
    .onAppear {
      self.rootData.fetch()
    }
  }

  @Namespace private var sidebarNamespace

  var sidebar: some View {
    Group {
      if let spaceId = navigation.activeSpaceId {
        SpaceSidebar(spaceId: spaceId)
      } else {
        HomeSidebar()
      }
    }
    .navigationSplitViewColumnWidth(min: Theme.minimumSidebarWidth, ideal: 240, max: 400)
  }

  var detail: some View {
    Group {
      if let spaceId = navigation.activeSpaceId {
        NavigationStack(path: navigation.spacePath) {
          renderSpaceRoute(for: navigation.spaceSelection.wrappedValue, spaceId: spaceId)
            .navigationDestination(for: NavigationRoute.self) { route in
              renderSpaceRoute(for: route, spaceId: spaceId)
            }
        }
      } else {
        NavigationStack(path: $navigation.homePath) {
          Text("Welcome to Inline")
            .navigationTitle("Home")
        }
      }
    }
  }

  func renderSpaceRoute(for destination: NavigationRoute, spaceId: Int64) -> some View {
    Group {
      switch destination {
      case .spaceRoot:
        SpaceView(spaceId: spaceId)
      case .chat(let peer):
        Text("Peer \(peer)")

      case .homeRoot:
        // Not for space
        Text("")
      }
    }
  }
}

#Preview {
  MainView()
    .previewsEnvironment(.empty)
    .environmentObject(NavigationModel())
}
