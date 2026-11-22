import Auth
import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import UIKit

/// Switches between startup loading, onboarding and the signed-in shell, following
/// `MainViewRouter.route`. Owns logout triggers. Replaces `ExperimentalRootView`.
@MainActor
final class AppRootViewController: UIViewController {
  let appDelegate: AppDelegate
  let router: Router
  let mainViewRouter = MainViewRouter()
  private weak var sceneDelegate: SceneDelegate?
  private var current: UIViewController?
  private var currentRoute: MainRoutes?
  private var cancellables: Set<AnyCancellable> = []

  init(appDelegate: AppDelegate, router: Router, sceneDelegate: SceneDelegate) {
    self.appDelegate = appDelegate
    self.router = router
    self.sceneDelegate = sceneDelegate
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    // Synchronous first route: a signed-in launch shows the cached shell in the first frame.
    show(route: mainViewRouter.route)
    mainViewRouter.$route
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] route in self?.show(route: route) }
      .store(in: &cancellables)

    let center = NotificationCenter.default
    center.publisher(for: .realtimeV2AuthInvalidated)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard let receipt = notification.object as? AuthInvalidationReceipt else { return }
        self?.performLogout(receipt: receipt)
      }
      .store(in: &cancellables)
    center.publisher(for: .authAccountRecoveryRequired)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.performLogout(receipt: nil) }
      .store(in: &cancellables)

    Task { [weak self] in
      guard await Auth.shared.hasPendingLogout() else { return }
      self?.performLogout(receipt: nil)
    }
  }

  private func performLogout(receipt: AuthInvalidationReceipt?) {
    let main = mainViewRouter
    let router = router
    let navigation = appDelegate.nav
    Task {
      await LogoutPerformer.perform(
        notifyServer: false,
        invalidationReceipt: receipt,
        mainRouter: main,
        navigation: navigation,
        onboardingNavigation: main.onboardingNavigation,
        router: router
      )
    }
  }

  private func show(route: MainRoutes) {
    guard route != currentRoute else { return }
    currentRoute = route
    let next: UIViewController
    switch route {
    case .main:
      // A fresh shell per sign-in so bootstrap state never crosses accounts.
      next = MainShellController(
        router: router,
        appDelegate: appDelegate,
        mainViewRouter: mainViewRouter,
        restoredHomeState: sceneDelegate?.restoredHomeState ?? [:]
      )
    case .onboarding:
      WhatsNewStore.shared.markSeen()
      next = AuthFlowController(router: mainViewRouter)
    case .loading:
      next = StartupLoadingViewController(router: mainViewRouter)
    }
    transition(to: next)
  }

  private func transition(to next: UIViewController) {
    let previous = current
    addChild(next)
    next.view.frame = view.bounds
    next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(next.view)
    next.didMove(toParent: self)
    current = next
    setNeedsStatusBarAppearanceUpdate()

    guard let previous else { return }
    previous.willMove(toParent: nil)
    if view.window != nil, !UIAccessibility.isReduceMotionEnabled {
      next.view.alpha = 0
      UIView.animate(withDuration: 0.25, animations: {
        next.view.alpha = 1
      }, completion: { _ in
        previous.view.removeFromSuperview()
        previous.removeFromParent()
      })
    } else {
      previous.view.removeFromSuperview()
      previous.removeFromParent()
    }
  }

  override var childForStatusBarStyle: UIViewController? { current }
  override var childForHomeIndicatorAutoHidden: UIViewController? { current }

  /// Scene-scoped home state for restoration.
  func homeSceneState() -> [String: String] {
    (current as? MainShellController)?.sceneState() ?? sceneDelegate?.restoredHomeState ?? [:]
  }
}

// MARK: - Startup loading

/// Shown while local storage and the account settle. Offers a retry after a delay, like
/// `IOSStartupLoadingView`.
@MainActor
final class StartupLoadingViewController: UIViewController {
  private let router: MainViewRouter
  private let spinner = UIActivityIndicatorView(style: .large)
  private let retryButton = PrimaryButton(title: String(localized: "Try Again"), style: .tinted)
  private let messageLabel = UILabel()
  private var revealTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []

  init(router: MainViewRouter) {
    self.router = router
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    spinner.startAnimating()
    messageLabel.text = String(localized: "Inline is taking longer than usual to open.")
    messageLabel.font = .preferredFont(forTextStyle: .subheadline)
    messageLabel.textColor = .secondaryLabel
    messageLabel.textAlignment = .center
    messageLabel.numberOfLines = 0
    retryButton.setAction { [weak self] in self?.router.retryStartup() }

    let recovery = UIStackView(arrangedSubviews: [messageLabel, retryButton])
    recovery.axis = .vertical
    recovery.spacing = 16
    recovery.alpha = 0

    let stack = UIStackView(arrangedSubviews: [spinner, recovery])
    stack.axis = .vertical
    stack.spacing = 28
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor, constant: -24),
      recovery.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])

    revealTask = Task { [weak recovery] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      UIView.animate(withDuration: 0.25) { recovery?.alpha = 1 }
    }
    router.$isRetryingStartup
      .sink { [weak self] retrying in self?.retryButton.isLoading = retrying }
      .store(in: &cancellables)
  }

  deinit { revealTask?.cancel() }
}
