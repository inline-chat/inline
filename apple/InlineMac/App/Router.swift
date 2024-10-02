
import AppKit
import Cocoa

enum Route {
    case onboarding
    case main
}

class Router {
    static let shared = Router()
    private init() {}

    func navigate(to route: Route) {
        let viewController: NSViewController

        switch route {
        case .onboarding:
            viewController = OnboardingViewController()
            App.shared.mainWindowController?.setWindowStyle(.onboarding)
        case .main:
            viewController = MainViewController()
            App.shared.mainWindowController?.setWindowStyle(.splitView)
        }
  
        if let window = App.shared.mainWindow {
            window.contentViewController = viewController
        }
    }
}
