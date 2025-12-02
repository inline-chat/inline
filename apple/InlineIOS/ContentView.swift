import InlineKit
import InlineUI
import Invite
import Logger
import SwiftUI

struct ContentView2: View {
  @Environment(\.auth) private var auth
  @Environment(\.scenePhase) private var scene
  @Environment(\.realtime) var realtime

  @EnvironmentStateObject private var data: DataManager
  @EnvironmentStateObject private var home: HomeViewModel
  @EnvironmentStateObject private var compactSpaceList: CompactSpaceList

  @StateObject private var onboardingNav = OnboardingNavigation()
  @StateObject var api = ApiClient()
  @StateObject var userData = UserData()
  @StateObject var mainViewRouter = MainViewRouter()
  @StateObject private var fileUploadViewModel = FileUploadViewModel()
  @StateObject private var tabsManager = TabsManager()

  @Environment(Router.self) private var router

  init() {
    _data = EnvironmentStateObject { env in
      DataManager(database: env.appDatabase)
    }

    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }

    _compactSpaceList = EnvironmentStateObject { env in
      CompactSpaceList(db: env.appDatabase)
    }
  }

  var body: some View {
    Group {
      content
    }
    .environment(router)
    .environmentObject(onboardingNav)
    .environmentObject(Api.realtime.stateObject)
    .environmentObject(api)
    .environmentObject(userData)
    .environmentObject(data)
    .environmentObject(mainViewRouter)
    .environmentObject(home)
    .environmentObject(fileUploadViewModel)
    .environmentObject(tabsManager)
    .environmentObject(compactSpaceList)
    .toastView()
  }

  @ViewBuilder
  var content: some View {
    @Bindable var bindableRouter = router

    switch mainViewRouter.route {
    case .main:
      TabView(selection: $bindableRouter.selectedTab) {
        ForEach(AppTab.allCases) { tab in
          NavigationStack(path: $bindableRouter[tab]) {
            tabContentView(for: tab)
              .navigationDestination(for: Destination.self) { destination in
                destinationView(for: destination)
              }
          }
          .tabItem {
            Label(tab.rawValue.capitalized, systemImage: tab.icon)
          }
          .tag(tab)
        }
      }
      .background(Color(.systemBackground))
      //Accent()
      .sheet(item: $bindableRouter.presentedSheet) { sheet in
        sheetView(for: sheet)
      }
    case .onboarding:
      OnboardingView()
    }
  }

  @ViewBuilder
  private func tabContentView(for tab: AppTab) -> some View {
    switch tab {
    case .chats:
      HomeView()
    case .archived:
      ArchivedChatsView()
    case .spaces:
      SpacesView()
    }
  }

  @ViewBuilder
  private func destinationView(for destination: Destination) -> some View {
    switch destination {
    case .chats:
      HomeView()
    case .archived:
      ArchivedChatsView()
    case .spaces:
      SpacesView()
    case let .space(id):
      SpaceView(spaceId: id)
    case let .chat(peer):
      ChatView(peer: peer)
    case let .chatInfo(chatItem):
      ChatInfoView(chatItem: chatItem)
    case let .spaceSettings(spaceId):
      SpaceSettingsView(spaceId: spaceId)
    case let .spaceIntegrations(spaceId):
      SpaceIntegrationsView(spaceId: spaceId)
    case let .integrationOptions(spaceId, provider):
      IntegrationOptionsView(spaceId: spaceId, provider: provider)
    case let .createThread(spaceId):
      CreateChatView(spaceId: spaceId)
    case .createSpaceChat:
      CreateChatView(spaceId: nil)
    }
  }

  @ViewBuilder
  private func sheetView(for sheet: Sheet) -> some View {
    switch sheet {
    case .createSpace:
      CreateSpace()

    case .alphaSheet:
      AlphaSheet()

    case .settings:
      NavigationStack {
        SettingsView()
      }

    case let .addMember(spaceId):
      // AddMember(showSheet: showSheet, spaceId: spaceId)
      InviteToSpaceView(spaceId: spaceId)
    }
  }
}
