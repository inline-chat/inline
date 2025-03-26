import Auth
import Foundation
import InlineKit
import Logger
import SwiftUI

public enum MainRoutes {
  case main
  case onboarding
}

public class MainViewRouter: ObservableObject {
  @Published var route: MainRoutes

  init() {
    Log.shared.info("MainViewRouter init called. Is logged in \(Auth.shared.isLoggedIn)")
    if Auth.shared.getIsLoggedIn() == true { route = .main } else { route = .onboarding }
  }

  public func setRoute(route: MainRoutes) {
    self.route = route
  }
}
