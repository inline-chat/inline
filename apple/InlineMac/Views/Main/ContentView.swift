import AppKit
import Combine
import InlineKit
import Logger

/// A root content view controller that manages the display of different content based on current route
class ContentViewController: NSViewController {
  private var dependencies: AppDependencies
  private var log = Log.scoped("ContentView")
  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)
  }

  private var currentlyRenderedRoute: NavEntry.Route?
  private var cancellables = Set<AnyCancellable>()

  override func loadView() {
    view = NSView()
    view.wantsLayer = true

    // move to did load?
    switchToRoute(dependencies.nav.currentRoute)
    dependencies.nav.currentRoutePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] route in
        self?.switchToRoute(route)
      }.store(in: &cancellables)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func removePreviousRoute() {
    children.forEach { $0.removeFromParent() }
    view.subviews.forEach { $0.removeFromSuperview() }
  }

  private func switchToRoute(_ route: NavEntry.Route) {
    log.debug("Switching to route: \(route)")

    // Skip if duplicate
    if route == currentlyRenderedRoute {
      log.debug("Skipped")
      return
    }

    currentlyRenderedRoute = route

    // Properly remove previous view controller
    if let currentVC = currentRouteViewController {
      if let currentVC = currentVC as? ChatViewAppKit {
        currentVC.dispose()
      }

      currentVC.view.removeFromSuperview()
      currentVC.removeFromParent()
      currentRouteViewController = nil
    }

    if let currentView = currentRouteSubview {
      currentView.removeFromSuperview()
      currentRouteSubview = nil
    }

    // removePreviousRoute()

    switch route {
      case .empty:
        break

      case let .chat(peer):
        let chatView = ChatViewAppKit(peerId: peer, dependencies: dependencies)
        addRouteSubview(chatView.view, chatView)

      case .createSpace:
        let createSpaceVC = CreateSpaceViewController(dependencies: dependencies)
        addRouteSubview(createSpaceVC.view, createSpaceVC)

      case let .newChat(spaceId):
        let newChatVC = NewChatViewController(spaceId: spaceId, dependencies: dependencies)
        addRouteSubview(newChatVC.view, newChatVC)

      case let .inviteToSpace(spaceId):
        let inviteToSpaceVC = InviteToSpaceViewController(spaceId: spaceId, dependencies: dependencies)
        addRouteSubview(inviteToSpaceVC.view, inviteToSpaceVC)

      default:
        break
    }
  }

  var currentRouteSubview: NSView? = nil
  var currentRouteViewController: NSViewController? = nil

  private func addRouteSubview(_ subview: NSView, _ viewController: NSViewController? = nil) {
    // Add the view controller as a child first
    if let viewController {
      addChild(viewController)
    }

    // Then add and configure the view
    currentRouteSubview = subview
    currentRouteViewController = viewController

    subview.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(subview)
    if let viewController {
      addChild(viewController)
    }

    NSLayoutConstraint.activate([
      subview.topAnchor.constraint(equalTo: view.topAnchor),
      subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }
}
