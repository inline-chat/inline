import Foundation
import InlineKit
import SwiftUI
import Auth


public enum MainRoutes {
  case main
  case onboarding
}

public class MainViewRouter: ObservableObject {
  @Published var route: MainRoutes = .main
  init() {
    print("MainViewRouter init called")
    if Auth.shared.isLoggedIn { route = .main } else { route = .onboarding }
  }

  public func setRoute(route: MainRoutes) {
    self.route = route
  }
}
