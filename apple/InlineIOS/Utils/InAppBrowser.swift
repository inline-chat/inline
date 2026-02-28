import SafariServices
import UIKit

final class InAppBrowser: NSObject {
  static let shared = InAppBrowser()

  private static let supportedSchemes: Set<String> = ["http", "https"]
  private static let universalLinkOptions: [UIApplication.OpenExternalURLOptionsKey: Any] = [
    .universalLinksOnly: true,
  ]
  private weak var presentedSafariViewController: SFSafariViewController?

  private override init() {}

  func open(_ url: URL, from presenter: UIViewController? = nil) {
    if Thread.isMainThread {
      openOnMain(url, from: presenter)
      return
    }

    DispatchQueue.main.async { [weak self] in
      self?.openOnMain(url, from: presenter)
    }
  }

  func dismissIfPresented(animated: Bool = true) {
    if Thread.isMainThread {
      dismissOnMain(animated: animated)
      return
    }

    DispatchQueue.main.async { [weak self] in
      self?.dismissOnMain(animated: animated)
    }
  }

  private func openOnMain(_ url: URL, from presenter: UIViewController?) {
    guard let scheme = url.scheme?.lowercased() else { return }

    guard Self.supportedSchemes.contains(scheme) else {
      UIApplication.shared.open(url)
      return
    }

    UIApplication.shared.open(url, options: Self.universalLinkOptions) { [weak self, weak presenter] openedInApp in
      guard let self else { return }
      guard !openedInApp else { return }
      self.presentInAppSafari(url, from: presenter)
    }
  }

  private func presentInAppSafari(_ url: URL, from presenter: UIViewController?) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.presentInAppSafari(url, from: presenter)
      }
      return
    }

    guard let presentingViewController = resolvedPresenter(from: presenter) else {
      UIApplication.shared.open(url)
      return
    }

    let safariViewController = SFSafariViewController(url: url)
    safariViewController.delegate = self
    safariViewController.dismissButtonStyle = .close
    safariViewController.modalPresentationStyle = .pageSheet
    if let sheet = safariViewController.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.selectedDetentIdentifier = .large
      sheet.prefersGrabberVisible = true
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }

    presentedSafariViewController = safariViewController
    presentingViewController.present(safariViewController, animated: true)
  }

  private func dismissOnMain(animated: Bool) {
    guard let safariViewController = presentedSafariViewController,
          safariViewController.presentingViewController != nil
    else {
      return
    }

    safariViewController.dismiss(animated: animated)
    presentedSafariViewController = nil
  }

  private func resolvedPresenter(from presenter: UIViewController?) -> UIViewController? {
    var candidate = topViewController(from: presenter) ?? topViewControllerFromActiveScene()

    if let alert = candidate as? UIAlertController {
      candidate = alert.presentingViewController
    }

    return candidate
  }

  private func topViewControllerFromActiveScene() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })

    let keyWindow = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    return topViewController(from: keyWindow?.rootViewController)
  }

  private func topViewController(from controller: UIViewController?) -> UIViewController? {
    if let navigationController = controller as? UINavigationController {
      return topViewController(from: navigationController.visibleViewController)
    }

    if let tabBarController = controller as? UITabBarController {
      return topViewController(from: tabBarController.selectedViewController)
    }

    if let splitViewController = controller as? UISplitViewController,
       let lastViewController = splitViewController.viewControllers.last
    {
      return topViewController(from: lastViewController)
    }

    if let presented = controller?.presentedViewController, !presented.isBeingDismissed {
      return topViewController(from: presented)
    }

    return controller
  }
}

extension InAppBrowser: SFSafariViewControllerDelegate {
  func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
    if presentedSafariViewController === controller {
      presentedSafariViewController = nil
    }
  }
}
