import Foundation
import SwiftUI

public enum MainRoutes {
  case main
  case onboarding
}

public class MainViewRouter: ObservableObject {
  @Published var route: MainRoutes = .main

  public func setRoute(route: MainRoutes) {
    self.route = route
  }
}
