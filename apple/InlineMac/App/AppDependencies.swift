import SwiftUI
import Auth
import InlineKit

@MainActor
public struct AppDependencies {
  let auth = Auth.shared
  let viewModel = MainWindowViewModel()
  let overlay = OverlayManager()
  let navigation = NavigationModel.shared
  let transactions = Transactions.shared
  let realtime = Realtime.shared
  let database = AppDatabase.shared
  let data = DataManager(database: AppDatabase.shared)
  let userSettings = INUserSettings.current

  // Per window
  let nav: Nav = .main
  var keyMonitor: KeyMonitor?

  // Optional
  var rootData: RootData?
  var logOut: (() async -> Void) = {}
}

extension View {
  func environment(dependencies deps: AppDependencies) -> AnyView {
    var result = environment(\.auth, deps.auth)
      .environmentObject(deps.viewModel)
      .environmentObject(deps.overlay)
      .environmentObject(deps.navigation)
      .environmentObject(deps.nav)
      .environmentObject(deps.data)
      .environmentObject(deps.userSettings.notification)
      .environment(\.transactions, deps.transactions)
      .environment(\.realtime, deps.realtime)
      .appDatabase(deps.database)
      .environment(\.logOut, deps.logOut)
      .environment(\.keyMonitor, deps.keyMonitor)
      .environment(\.dependencies, deps)
      .eraseToAnyView()

    if let rootData = deps.rootData {
      result = result.environmentObject(rootData).eraseToAnyView()
    }

    return result
  }
}
