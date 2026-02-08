import InlineKit
import InlineUI
import Invite
import Logger
import SwiftUI

struct ContentView2: View {
  @Environment(\.auth) private var auth
  @Environment(\.scenePhase) private var scene
  @Environment(\.realtime) var realtime

  @StateObject private var onboardingNav = OnboardingNavigation()
  @StateObject var api = ApiClient()
  @StateObject var userData = UserData()
  @StateObject var mainViewRouter = MainViewRouter()
  @StateObject private var fileUploadViewModel = FileUploadViewModel()
  @StateObject private var tabsManager = TabsManager()

  @Environment(Router.self) private var router

  var body: some View {
    Group {
      content
    }
    .environment(router)
    .environmentObject(onboardingNav)
    .environmentObject(Api.realtime.stateObject)
    .environmentObject(api)
    .environmentObject(userData)
    .environmentObject(mainViewRouter)
    .environmentObject(fileUploadViewModel)
    .environmentObject(tabsManager)
    .toastView()
  }

  @ViewBuilder
  var content: some View {
    switch mainViewRouter.route {
    case .loading:
      VStack(spacing: 12) {
        ProgressView()
        Text("Unlocking...")
          .font(.headline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(.systemBackground))
    case .main:
      AuthedAppRoot(database: AppDatabase.shared)
        .appDatabase(AppDatabase.shared)
    case .onboarding:
      OnboardingView()
    }
  }
}

private struct AuthedAppRoot: View {
  @Environment(Router.self) private var router

  private let database: AppDatabase

  @StateObject private var data: DataManager
  @StateObject private var home: HomeViewModel
  @StateObject private var compactSpaceList: CompactSpaceList

  init(database: AppDatabase) {
    self.database = database
    _data = StateObject(wrappedValue: DataManager(database: database))
    _home = StateObject(wrappedValue: HomeViewModel(db: database))
    _compactSpaceList = StateObject(wrappedValue: CompactSpaceList(db: database))
  }

  var body: some View {
    @Bindable var bindableRouter = router

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
    .sheet(item: $bindableRouter.presentedSheet) { sheet in
      sheetView(for: sheet)
    }
    .environmentObject(data)
    .environmentObject(home)
    .environmentObject(compactSpaceList)
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
    case .createSpace:
      CreateSpaceView()
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
      InviteToSpaceView(spaceId: spaceId)
    }
  }
}
