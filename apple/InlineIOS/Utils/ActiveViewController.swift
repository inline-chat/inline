import UIKit

@MainActor
func activeTopViewController() -> UIViewController? {
  activeTopViewController(in: .shared)
}

@MainActor
func activeTopViewController(in application: UIApplication) -> UIViewController? {
  let windows = application.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .filter { $0.activationState == .foregroundActive }
    .flatMap(\.windows)

  let window = windows.first(where: \.isKeyWindow) ?? windows.first {
    !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal
  }

  return topViewController(from: window?.rootViewController)
}

@MainActor
private func topViewController(from controller: UIViewController?) -> UIViewController? {
  guard let controller else { return nil }

  if let presented = controller.presentedViewController, !presented.isBeingDismissed {
    return topViewController(from: presented)
  }

  if let navigationController = controller as? UINavigationController {
    return topViewController(from: navigationController.visibleViewController)
  }

  if let tabBarController = controller as? UITabBarController {
    return topViewController(from: tabBarController.selectedViewController)
  }

  if let splitViewController = controller as? UISplitViewController,
     let visibleController = splitViewController.viewControllers.last {
    return topViewController(from: visibleController)
  }

  return controller
}
