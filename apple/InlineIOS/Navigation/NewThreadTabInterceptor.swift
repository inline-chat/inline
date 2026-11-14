import SwiftUI
import UIKit

/// Makes the root New Thread tab an action instead of a page.
///
/// SwiftUI has no action tabs: tapping one lets UIKit switch to its empty page before the
/// selection binding can refuse it, and the chats behind the New Thread sheet disappear until
/// SwiftUI's next update switches back. This sits behind the `TabView`, finds its
/// `UITabBarController`, and answers UIKit's "should select" for that tab with the action and
/// `false`, forwarding everything else to SwiftUI's own delegate.
struct NewThreadTabInterceptor: UIViewRepresentable {
  /// The New Thread tab's title, as the `Tab` shows it.
  let title: String
  let action: () -> Void

  func makeUIView(context: Context) -> InterceptorView {
    InterceptorView()
  }

  func updateUIView(_ view: InterceptorView, context: Context) {
    view.title = title
    view.action = action
    view.install()
  }

  final class InterceptorView: UIView {
    var title = ""
    var action: (() -> Void)?
    private let proxy = DelegateProxy()

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      install()
      // The tab controller may join the hierarchy after this view.
      DispatchQueue.main.async { [weak self] in self?.install() }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      // SwiftUI can set its delegate again when the tabs change.
      install()
    }

    private weak var tabBarController: UITabBarController?

    func install() {
      guard window != nil else { return }
      proxy.title = title
      proxy.action = { [weak self] in self?.action?() }
      guard let tabBarController = tabBarController ?? findTabBarController() else { return }
      self.tabBarController = tabBarController
      guard tabBarController.delegate !== proxy else { return }
      proxy.original = tabBarController.delegate
      tabBarController.delegate = proxy
    }

    /// This view sits beside the `TabView`, not inside it: walk up to the nearest view
    /// controller, then look through its children (and its parents') for the tab controller.
    private func findTabBarController() -> UITabBarController? {
      var responder: UIResponder? = self
      while let current = responder, !(current is UIViewController) {
        responder = current.next
      }
      var controller = responder as? UIViewController
      while let current = controller {
        if let found = Self.descendantTabBarController(of: current) { return found }
        controller = current.parent
      }
      return nil
    }

    private static func descendantTabBarController(of controller: UIViewController) -> UITabBarController? {
      if let tabs = controller as? UITabBarController { return tabs }
      for child in controller.children {
        if let found = descendantTabBarController(of: child) { return found }
      }
      return nil
    }
  }

  final class DelegateProxy: NSObject, UITabBarControllerDelegate {
    weak var original: UITabBarControllerDelegate?
    var title = ""
    var action: (() -> Void)?

    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
      if tab.title == title, tab === tabBarController.tabs.last {
        action?()
        return false
      }
      return original?.tabBarController?(tabBarController, shouldSelectTab: tab) ?? true
    }

    func tabBarController(
      _ tabBarController: UITabBarController,
      shouldSelect viewController: UIViewController
    ) -> Bool {
      if let index = tabBarController.viewControllers?.firstIndex(of: viewController),
         index == (tabBarController.viewControllers?.count ?? 0) - 1,
         viewController.tabBarItem.title == title
      {
        action?()
        return false
      }
      return original?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
    }

    // Everything else goes to SwiftUI's delegate.
    override func responds(to aSelector: Selector!) -> Bool {
      super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
      if let original, original.responds(to: aSelector) { return original }
      return super.forwardingTarget(for: aSelector)
    }
  }
}
