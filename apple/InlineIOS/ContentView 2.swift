import InlineKit
import InlineUI
import Logger
import SwiftUI

struct ContentView2: View {
  @Environment(\.auth) private var auth
  @Environment(\.scenePhase) private var scene

  @EnvironmentStateObject private var data: DataManager
  @EnvironmentStateObject private var home: HomeViewModel

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
  }

  var body: some View {
    Group {
      content
    }
    .environment(router)
    .environmentObject(onboardingNav)
    .environmentObject(api)
    .environmentObject(userData)
    .environmentObject(data)
    .environmentObject(mainViewRouter)
    .environmentObject(home)
    .environmentObject(fileUploadViewModel)
    .environmentObject(tabsManager)
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
      case .settings:
        SettingsView()
      case let .spaceSettings(spaceId):
        SpaceSettingsView(spaceId: spaceId)
      case let .spaceIntegrations(spaceId):
        SpaceIntegrationsView(spaceId: spaceId)
      case let .integrationOptions(spaceId, provider):
        IntegrationOptionsView(spaceId: spaceId, provider: provider)
    }
  }

  @ViewBuilder
  private func sheetView(for sheet: Sheet) -> some View {
    switch sheet {
      case .createSpace:
        CreateSpace()
      case let .createThread(spaceId):
        CreateChatIOSView(spaceId: spaceId)
      case .alphaSheet:
        AlphaSheet()
    }
  }
}

struct SimpleChatListView: View {
  @EnvironmentObject private var home: HomeViewModel
  @EnvironmentObject private var dataManager: DataManager
  @Environment(Router.self) private var router

  var chatItems: [HomeChatItem] {
    home.chats.filter {
      $0.dialog.archived != true
    }.sorted { (item1: HomeChatItem, item2: HomeChatItem) in
      let pinned1 = item1.dialog.pinned ?? false
      let pinned2 = item2.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      return item1.lastMessage?.message.date ?? item1.chat?.date ?? Date.now > item2.lastMessage?.message.date ?? item2
        .chat?.date ?? Date.now
    }
  }

  var body: some View {
    ChatListView(
      items: chatItems,
      isArchived: false,
      onItemTap: { item in
        if let user = item.user {
          router.push(.chat(peer: .user(id: user.user.id)))
        } else if let chat = item.chat {
          router.push(.chat(peer: .thread(id: chat.id)))
        }
      },
      onArchive: { item in
        Task {
          if let user = item.user {
            try await dataManager.updateDialog(
              peerId: .user(id: user.user.id),
              archived: true
            )
          } else if let chat = item.chat {
            try await dataManager.updateDialog(
              peerId: .thread(id: chat.id),
              archived: true
            )
          }
        }
      },
      onPin: { item in
        Task {
          if let user = item.user {
            try await dataManager.updateDialog(
              peerId: .user(id: user.user.id),
              pinned: !(item.dialog.pinned ?? false)
            )
          } else if let chat = item.chat {
            try await dataManager.updateDialog(
              peerId: .thread(id: chat.id),
              pinned: !(item.dialog.pinned ?? false)
            )
          }
        }
      },
      onRead: { item in
        Task {
          UnreadManager.shared.readAll(item.dialog.peerId, chatId: item.chat?.id ?? 0)
        }
      }
    )
  }
}
