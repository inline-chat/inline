import InlineCompatUI
import InlineKit
import UIKit

/// A tab's navigation stack bound to `router[tab]`, the UIKit counterpart of
/// `NavigationStack(path:)`.
///
/// Router changes (pushes from rows, deep links, notifications, Siri) rebuild the stack, reusing
/// controllers whose destination is unchanged. Pops made by the person (Back, edge swipe) write
/// the shortened path back, so the router stays the single source of truth for restoration and
/// "is this chat on screen" checks.
@MainActor
final class RouterNavigationController: UINavigationController, UINavigationControllerDelegate {
  typealias Factory = @MainActor (Destination) -> UIViewController

  let routerTab: AppTab
  private let router: Router
  private let factory: Factory
  private var shown: [(destination: Destination, controller: UIViewController)] = []
  private var isApplyingRouter = false

  init(tab: AppTab, router: Router, root: UIViewController, factory: @escaping Factory) {
    self.routerTab = tab
    self.router = router
    self.factory = factory
    super.init(nibName: nil, bundle: nil)
    setViewControllers([root], animated: false)
    delegate = self
    navigationBar.prefersLargeTitles = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    // First sync is synchronous: a restored chat is on screen in the first frame.
    observe { [weak self] in
      guard let self else { return }
      self.apply(path: self.router[self.routerTab])
    }
  }

  var rootController: UIViewController? { viewControllers.first }

  /// The destination currently on top, if any.
  var topDestination: Destination? { shown.last?.destination }

  private func apply(path: [Destination]) {
    var reused: [(destination: Destination, controller: UIViewController)] = []
    for (index, destination) in path.enumerated() {
      if index < shown.count, shown[index].destination == destination {
        reused.append(shown[index])
      } else {
        break
      }
    }
    let created = path.dropFirst(reused.count).map { destination in
      (destination: destination, controller: factory(destination))
    }
    let next = reused + created
    let unchanged = next.count == shown.count
      && zip(next, shown).allSatisfy { $0.controller === $1.controller }
    guard !unchanged else { return }
    shown = next
    guard let root = rootController else { return }
    let stack = [root] + next.map(\.controller)
    isApplyingRouter = true
    let animated = view.window != nil && !UIAccessibility.isReduceMotionEnabled
    setViewControllers(stack, animated: animated)
    isApplyingRouter = false
  }

  // MARK: UINavigationControllerDelegate

  func navigationController(
    _ navigationController: UINavigationController,
    didShow viewController: UIViewController,
    animated: Bool
  ) {
    syncBackToRouter()
  }

  override func popViewController(animated: Bool) -> UIViewController? {
    let popped = super.popViewController(animated: animated)
    // An interactive pop finishes in didShow; a programmatic one is reflected now.
    if transitionCoordinator == nil { syncBackToRouter() }
    return popped
  }

  override func popToRootViewController(animated: Bool) -> [UIViewController]? {
    let popped = super.popToRootViewController(animated: animated)
    if transitionCoordinator == nil { syncBackToRouter() }
    return popped
  }

  /// Writes pops the person made back into the router.
  private func syncBackToRouter() {
    guard !isApplyingRouter else { return }
    let live = Set(viewControllers.map(ObjectIdentifier.init))
    let remaining = shown.filter { live.contains(ObjectIdentifier($0.controller)) }
    guard remaining.count != shown.count else { return }
    shown = remaining
    let path = remaining.map(\.destination)
    if router[routerTab] != path {
      router.setPathFromNavigation(path, for: routerTab)
    }
  }
}
