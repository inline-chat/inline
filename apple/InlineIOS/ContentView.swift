import InlineKit
import InlineUI
import Logger
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
  @StateObject private var tabsManager = TabsManager()

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
    .environmentObject(tabsManager)
    .toastView()
  }

  @ViewBuilder
  var content: some View {
    switch mainViewRouter.route {
      case .main:
        NavigationStack(path: $nav.pathComponents) {
          HomeView()
            .navigationDestination(for: Navigation.Destination.self) { destination in
              nav.destinationView(for: destination)
            }
        }
        .sheet(item: $nav.activeSheet) { destination in
          nav.sheetContent(for: destination)
            .presentationDetents([.medium, .large])
            .presentationBackground(.thickMaterial)
            .presentationCornerRadius(28)
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
