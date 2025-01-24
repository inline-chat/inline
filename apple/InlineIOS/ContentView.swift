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
  }
}

extension ContentView {
  @ViewBuilder
  func destinationView(for destination: Navigation.Destination) -> some View {
    switch destination {
    case .chat(let peer):
      ChatView(peer: peer)
    case .space(let id):
      SpaceView(spaceId: id)
    case .settings:
      Settings()
    case .main:
      MainView()
    case .archivedChats:
      ArchivedChatsView()
    case .createSpace, .createThread:
      // Handled by sheets
      EmptyView()
    }
  }

  @ViewBuilder
  func sheetContent(for destination: Navigation.Destination) -> some View {
    switch destination {
    case .createSpace:
      CreateSpace(showSheet: .constant(true))
        .presentationBackground(.ultraThickMaterial)
        .presentationCornerRadius(18)

    case .createThread(let spaceId):
      CreateThread(showSheet: .constant(true), spaceId: spaceId)
        .presentationBackground(.ultraThickMaterial)
        .presentationCornerRadius(18)
    case .settings:
      Settings()
        .presentationBackground(.ultraThickMaterial)
        .presentationCornerRadius(18)
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  var content: some View {
    switch mainViewRouter.route {
    case .main:
      NavigationStack(path: nav.currentStackBinding) {
        MainView()
          .navigationDestination(for: Navigation.Destination.self) { destination in
            destinationView(for: destination)
          }
      }
      .sheet(item: $nav.activeSheet) { destination in
        sheetContent(for: destination)
      }
      .onAppear {
        updateOnlineStatus()
      }
      .onChange(of: scene) { _, newScene in
        switch newScene {
        case .active:
          updateOnlineStatus()
        case .inactive:
          break
        case .background:
          break
        default:
          break
        }
      }

    case .onboarding:
      OnboardingView()
    }
  }

  func updateOnlineStatus() {
    Task {
      try? await data.updateStatus(online: true)
    }
  }
}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
}
