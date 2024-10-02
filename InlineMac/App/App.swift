import AppKit

class App {
    static let shared = App()
    
    private(set) var mainWindow: NSWindow?
    private(set) var mainWindowController: MainWindowProtocol?
    
    private init() {}
    
    func setMainWindow(_ windowController: MainWindowProtocol) {
        self.mainWindowController = windowController
        self.mainWindow = mainWindowController?.window
    }
    
    func navigate(to route: Route) {
        Router.shared.navigate(to: route)
    }
}
