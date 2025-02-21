import InlineKit
import SwiftUI

struct ContentView: View {
  @Environment(\.auth) private var auth
  @Environment(\.scenePhase) private var scene

  @EnvironmentObject private var nav: Navigation
  @EnvironmentStateObject private var data: DataManager
  @EnvironmentStateObject private var home: HomeViewModel

  @StateObject private var onboardingNav = OnboardingNavigation()
  @StateObject var api = ApiClient()
  @StateObject var userData = UserData()
  @StateObject var mainViewRouter = MainViewRouter()
  @StateObject private var fileUploadViewModel = FileUploadViewModel()

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
    .environmentObject(onboardingNav)
    .environmentObject(nav)
    .environmentObject(api)
    .environmentObject(userData)
    .environmentObject(data)
    .environmentObject(mainViewRouter)
    .environmentObject(home)
    .environmentObject(fileUploadViewModel)
    .toastView()
  }
}

extension ContentView {
  @ViewBuilder
  func destinationView(for destination: Navigation.Destination) -> some View {
    switch destination {
      case let .chat(peer):
        ChatView(peer: peer)
      case let .space(id):
        SpaceView(spaceId: id)
      case .settings:
        SettingsView()
      case .main:
        HomeView()
      case .archivedChats:
        ArchivedChatsView()
      case .createSpace:
        EmptyView()
      case .createThread:
        EmptyView()
      case .profile:
        EmptyView()
    }
  }

  @ViewBuilder
  func sheetContent(for destination: Navigation.Destination) -> some View {
    switch destination {
      case let .createThread(spaceId):
        CreateThread(spaceId: spaceId)
          .presentationCornerRadius(18)

      case .createSpace:
        CreateSpace()
          .presentationCornerRadius(18)

      case let .profile(userInfo):
        ProfilePage(userInfo: userInfo)

      default:
        EmptyView()
    }
  }

  @ViewBuilder
  var content: some View {
    switch mainViewRouter.route {
      case .main:
        NavigationStack(path: $nav.pathComponents) {
          HomeView()
            .navigationDestination(for: Navigation.Destination.self) { destination in
              destinationView(for: destination)
            }
        }
        .sheet(item: $nav.activeSheet) { destination in
          sheetContent(for: destination)
        }
        .onAppear {
          markAsOnline()
        }
        .onChange(of: scene) { _, newScene in
          switch newScene {
            case .active:
              markAsOnline()
            case .inactive:
              markAsOffline()
            case .background:
              markAsOffline()
            default:
              break
          }
        }

      case .onboarding:
        OnboardingView()
    }
  }

  private func markAsOnline() {
    Task {
      try? await data.updateStatus(online: true)
    }
  }

  private func markAsOffline() {
    Task {
      try? await data.updateStatus(online: false)
    }
  }
}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
}
