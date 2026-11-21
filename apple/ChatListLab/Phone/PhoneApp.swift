import UIKit

@main
final class PhoneApp: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "ChatList Lab", sessionRole: session.role)
    configuration.delegateClass = PhoneScene.self
    return configuration
  }
}

final class PhoneScene: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = PhoneLabController()
    window.makeKeyAndVisible()
    self.window = window
  }
}
