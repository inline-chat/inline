import Auth
import Combine
import InlineCompatUI
import InlineGrid
import InlineKit
import Logger
import UIKit

/// One window per scene: owns the scene's router, restores it, routes URLs and keeps the
/// scene registry (notifications, Siri, deep links) informed. Replaces `InlineSceneRoot`.
@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  private static let sceneMigrationKey = "ios.navigation.didMigrateToSceneStorage.v1"
  static let routerStateKey = "ios.navigation.routerState.v1"
  static let homeStateKey = "ios.home.sceneState.v1"

  var window: UIWindow?
  let sceneID = UUID()
  private(set) var router: Router!
  private var appDelegate: AppDelegate { UIApplication.shared.delegate as! AppDelegate }
  private var cancellables: Set<AnyCancellable> = []
  private var returningFromBackground = false
  private var lastUserID: Int64?
  /// Scene-scoped home state (active space, filters) restored with the scene.
  private(set) var restoredHomeState: [String: String] = [:]

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let restoresLegacy = !UserDefaults.standard.bool(forKey: Self.sceneMigrationKey)
    let router = Router(
      initialTab: .allChats,
      persistence: .externallyManaged,
      restoresPersistedState: restoresLegacy
    )
    if let data = session.stateRestorationActivity?.userInfo?[Self.routerStateKey] as? Data {
      _ = router.restorePersistentState(from: data)
    }
    if let home = session.stateRestorationActivity?.userInfo?[Self.homeStateKey] as? [String: String] {
      restoredHomeState = home
    }
    UserDefaults.standard.set(true, forKey: Self.sceneMigrationKey)
    self.router = router

    let window = UIWindow(windowScene: windowScene)
    window.tintColor = ThemeManager.shared.selected.accent
    let root = AppRootViewController(appDelegate: appDelegate, router: router, sceneDelegate: self)
    window.rootViewController = root
    self.window = window
    window.makeKeyAndVisible()
    ToastPresenter.shared.attach(to: window)

    let registry = appDelegate.sceneRouterRegistry
    registry.register(
      router,
      sceneID: sceneID,
      isActive: windowScene.activationState == .foregroundActive,
      accountUserID: Auth.shared.currentUserId
    )
    registry.attachWindow(window, sceneID: sceneID)
    lastUserID = Auth.shared.currentUserId

    observeAccount()
    observeTheme()
    observeTranslationNotices()

    for context in connectionOptions.urlContexts {
      handle(url: context.url)
    }
    for activity in connectionOptions.userActivities {
      handle(userActivity: activity)
    }
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    appDelegate.sceneRouterRegistry.unregister(sceneID)
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    appDelegate.sceneRouterRegistry.activate(sceneID)
    synchronizeUserSettings()
    ExtensionHealth.flush()
    // Which bots this person can reach: decides composers, mentions and search.
    if Auth.shared.isLoggedIn { AgentGrantStore.shared.start() }
    // After a real trip to the background, renew Grid presence and reconnect media now.
    if returningFromBackground, Auth.shared.isLoggedIn, let grid = GridRuntime.existing {
      Task { await grid.applicationDidWake() }
    }
    returningFromBackground = false
  }

  func sceneWillResignActive(_ scene: UIScene) {
    appDelegate.sceneRouterRegistry.deactivate(sceneID)
    Task { await NotificationSyncCleaner.shared.flush() }
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    returningFromBackground = true
  }

  // MARK: Restoration

  func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
    let activity = NSUserActivity(activityType: "chat.inline.scene")
    var info: [String: Any] = [:]
    if let data = router.encodedPersistentState() {
      info[Self.routerStateKey] = data
    }
    if let root = window?.rootViewController as? AppRootViewController {
      info[Self.homeStateKey] = root.homeSceneState()
    }
    activity.addUserInfoEntries(from: info)
    return activity
  }

  // MARK: URLs

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      handle(url: context.url)
    }
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    handle(userActivity: userActivity)
  }

  private func handle(userActivity: NSUserActivity) {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
      handle(url: url)
    }
  }

  private func handle(url: URL) {
    if ProviderSignInCoordinator.shared.canHandle(url) {
      Task { await ProviderSignInCoordinator.shared.handleCallback(url) }
    } else if InlineDeepLink.isCurrentAppScheme(url.scheme), ConnectorOAuthCallback(url: url) != nil {
      router.presentedSheet = .connectors(callbackURL: url.absoluteString)
    } else {
      _ = appDelegate.handleDeepLink(url, router: router)
    }
  }

  // MARK: Observation

  private func observeAccount() {
    Auth.shared.$currentUserId
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] newValue in
        guard let self else { return }
        let oldValue = lastUserID
        lastUserID = newValue
        appDelegate.sceneRouterRegistry.accountDidChange(from: oldValue, to: newValue)
        if newValue != nil {
          appDelegate.resumePendingSpaceJoin(router: router)
        }
      }
      .store(in: &cancellables)

    Auth.shared.$isLoggedIn
      .removeDuplicates()
      .dropFirst()
      .filter { $0 }
      .sink { _ in AgentGrantStore.shared.start() }
      .store(in: &cancellables)

    appDelegate.$spaceJoinErrorMessage
      .receive(on: DispatchQueue.main)
      .sink { [weak self] message in
        guard let message, let self, let root = window?.rootViewController else { return }
        let alert = UIAlertController(title: "Couldn’t join space", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
          self?.appDelegate.dismissSpaceJoinError()
        })
        root.topmostPresented.present(alert, animated: true)
      }
      .store(in: &cancellables)
  }

  private func observeTheme() {
    ThemeManager.shared.$selectedPreset
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.window?.tintColor = ThemeManager.shared.selected.accent
      }
      .store(in: &cancellables)
  }

  private func observeTranslationNotices() {
    AppDatabase.shared.translationPreferences.notices
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notice in
        guard self?.window?.windowScene?.activationState == .foregroundActive else { return }
        ToastManager.shared.showToast(notice.message, type: notice.isError ? .error : .info)
      }
      .store(in: &cancellables)
  }

  private func synchronizeUserSettings() {
    Task {
      await INUserSettings.current.refresh(reason: .authenticatedScene)
    }
  }
}
