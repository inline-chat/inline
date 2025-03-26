import Foundation
import InlineKit
import SwiftUI
import Auth
import Logger

public enum MainRoutes {
  case main
  case onboarding
}

public class MainViewRouter: ObservableObject {
  @Published var route: MainRoutes
  
  init() {
    Log.shared.info("MainViewRouter init called. Is logged in \(Auth.shared.isLoggedIn)")
    if Auth.shared.isLoggedIn { route = .main } else { route = .onboarding }
  }

  public func setRoute(route: MainRoutes) {
    self.route = route
  }
}
