import AppKit

struct MainWindowRestorationState {
  static let version = 1

  private enum Key {
    static let version = "version"
    static let sceneId = "sceneId"
    static let routeState = "routeState"
  }

  var sceneId: String
  var routeState: String

  init(sceneId: String, routeState: String) {
    self.sceneId = sceneId.isEmpty ? MainWindowSceneStateStore.makeSceneId() : sceneId
    self.routeState = Self.normalizedRouteState(routeState)
  }

  init?(coder: NSCoder) {
    let version = coder.decodeInteger(forKey: Key.version)
    guard version > 0, version <= Self.version else {
      return nil
    }

    let decodedSceneId = coder.decodeObject(of: NSString.self, forKey: Key.sceneId) as String?
    if let decodedSceneId, decodedSceneId.isEmpty == false {
      sceneId = decodedSceneId
    } else {
      sceneId = MainWindowSceneStateStore.makeSceneId()
    }

    let decodedRouteState = coder.decodeObject(of: NSString.self, forKey: Key.routeState) as String? ?? ""
    routeState = Self.normalizedRouteState(decodedRouteState)
  }

  func encode(with coder: NSCoder) {
    coder.encode(Self.version, forKey: Key.version)
    coder.encode(sceneId as NSString, forKey: Key.sceneId)
    coder.encode(routeState as NSString, forKey: Key.routeState)
  }

  private static func normalizedRouteState(_ routeState: String) -> String {
    Nav3RouteState(rawValue: routeState)?.rawValue ?? ""
  }
}

final class MainWindowRestoration: NSObject, NSWindowRestoration {
  static let identifier = "InlineMainWindowRestoration"

  static func restoreWindow(
    withIdentifier identifier: NSUserInterfaceItemIdentifier,
    state: NSCoder,
    completionHandler: @escaping (NSWindow?, Error?) -> Void
  ) {
    guard identifier == NSUserInterfaceItemIdentifier(Self.identifier) else {
      completionHandler(nil, nil)
      return
    }

    guard let restorationState = MainWindowRestorationState(coder: state) else {
      completionHandler(nil, nil)
      return
    }

    MainActor.assumeIsolated {
      guard let appDelegate = NSApp.delegate as? AppDelegate else {
        completionHandler(nil, nil)
        return
      }

      let controller = MainWindowSwiftUIWindowController.restore(
        dependencies: appDelegate.dependencies,
        state: restorationState
      )
      completionHandler(controller.window, nil)
    }
  }
}
