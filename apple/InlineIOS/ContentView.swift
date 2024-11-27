import InlineKit
import SwiftUI

struct ContentView: View {
  @Environment(\.auth) private var auth

  @EnvironmentObject private var nav: Navigation
  @EnvironmentStateObject private var dataManager: DataManager

  @StateObject private var onboardingNav = OnboardingNavigation()
  @StateObject var api = ApiClient()
  @StateObject var userData = UserData()
  @StateObject var mainViewRouter = MainViewRouter()

  init() {
    _dataManager = EnvironmentStateObject { env in
      DataManager(database: env.appDatabase)
    }
  }

  var body: some View {
    Group {
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
      case .onboarding:
        OnboardingView()
      }
    }
    .environmentObject(onboardingNav)
    .environmentObject(nav)
    .environmentObject(api)
    .environmentObject(userData)
    .environmentObject(dataManager)
    .environmentObject(mainViewRouter)
  }

}

// MARK: - Navigation destinations
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
    case .contacts:
      Contacts()
    case .createSpace, .createDM, .createThread:
      EmptyView()  // These are handled by sheets
    case .main:
      MainView()
    }
  }

  @ViewBuilder
  func sheetContent(for destination: Navigation.Destination) -> some View {
    switch destination {
    case .createSpace:
      CreateSpace(showSheet: .constant(true))
        .presentationBackground(.ultraThickMaterial)
        .presentationCornerRadius(18)
    case .createDM:
      CreateDm(showSheet: .constant(true))
        .presentationBackground(.ultraThickMaterial)
        .presentationCornerRadius(18)
        .presentationDetents([.medium, .large])
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
}
#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
}
