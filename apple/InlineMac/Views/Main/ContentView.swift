import AppKit
import Combine
import InlineKit

/// A root content view controller that manages the display of different content based on current route
class ContentViewController: NSViewController {
  private var dependencies: AppDependencies

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)
  }

  private var cancellables = Set<AnyCancellable>()

  override func loadView() {
    view = NSView()
    view.wantsLayer = true

    // move to did load?
    switchToRoute(dependencies.nav.currentRoute)
    dependencies.nav.currentRoutePublisher.sink { [weak self] route in
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
    removePreviousRoute()

    switch route {
      case .empty:
        break

      case let .chat(peer):
        let chatView = ChatViewAppKit(peerId: peer)
        chatView
          .update(viewModel: FullChatViewModel(db: dependencies.database, peer: peer))
        addRouteSubview(chatView)

      default:
        break
    }
  }

  private func addRouteSubview(_ subview: NSView) {
    subview.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(subview)
    NSLayoutConstraint.activate([
      subview.topAnchor.constraint(equalTo: view.topAnchor),
      subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }
}
