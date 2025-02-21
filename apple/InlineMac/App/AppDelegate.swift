import AppKit
import InlineConfig
import InlineKit
import Logger
import RealtimeAPI
import Sentry
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
  // Main Window
  private var mainWindowController: MainWindowController?

  // Common Dependencies
  @MainActor private let dependencies = AppDependencies()

  // --
  let notifications = NotificationsManager()
  let navigation: NavigationModel = .shared
  let log = Log.scoped("AppDelegate")

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Disable native tabbing
    NSWindow.allowsAutomaticWindowTabbing = false

    // Setup Notifications Delegate
    setupNotifications()
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    initializeServices()
    setupMainWindow()
    setupMainMenu()
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  func applicationDidResignActive(_ notification: Notification) {
    Task {
      // Mark offline
      try? await DataManager.shared.updateStatus(online: false)
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    Task {
      // Mark online
      try? await DataManager.shared.updateStatus(online: true)
    }
  }

  private func setupMainWindow() {
    let controller = MainWindowController(dependencies: dependencies)
    controller.showWindow(nil)
    mainWindowController = controller
  }

  private func initializeServices() {
    // Setup Sentry
    SentrySDK.start { options in
      options.dsn = InlineConfig.SentryDSN
      options.debug = false
      options.tracesSampleRate = 0.1
    }

    // Register for notifications
    notifications.setup()
  }
}

// MARK: - Notifications

extension AppDelegate {
  func setupNotifications() {
    notifications.setup()
    notifications.onNotificationReceived { response in
      self.handleNotification(response)
    }
    UNUserNotificationCenter.current().delegate = notifications
  }

  func application(
    _ application: NSApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    log.debug("Registered for remote notifications: \(deviceToken)")

    notifications.didRegisterForRemoteNotifications(deviceToken: deviceToken)
  }

  func application(
    _ application: NSApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    log.error("Failed to register for remote notifications \(error)")
  }

  func handleNotification(_ response: UNNotificationResponse) {
    log.debug("Received notification: \(response)")

    // TODO: Navigate
    guard let userInfo = response.notification.request.content.userInfo as? [String: Any] else {
      return
    }

    if let peerId = getPeerFromNotification(userInfo) {
      navigation.select(.chat(peer: peerId))
      // TODO: Handle spaceId
    }
  }

  func getPeerFromNotification(_ userInfo: [String: Any]) -> Peer? {
    if let peerUserId = userInfo["userId"] as? Int64 {
      .user(id: peerUserId)
    } else {
      nil
    }
  }

  private func setupMainMenu() {
    AppMenu.shared.setupMainMenu()
  }
}

// MARK: - Dependency Container

@MainActor
struct AppDependencies {
  let auth = Auth.shared
  let ws = WebSocketManager()
  let viewModel = MainWindowViewModel()
  let overlay = OverlayManager()
  let navigation = NavigationModel.shared
  let transactions = Transactions.shared
  let realtime = Realtime.shared
  let database = AppDatabase.shared
  let data = DataManager(database: AppDatabase.shared)

  // Per window
  let nav: Nav = .main

  // Optional
  var rootData: RootData?
  var logOut: (() async -> Void) = {}
  // Per window nav?
  // var nav =
}

extension View {
  func environment(dependencies deps: AppDependencies) -> AnyView {
    var result = environment(\.auth, deps.auth)
      .environmentObject(deps.ws)
      .environmentObject(deps.viewModel)
      .environmentObject(deps.overlay)
      .environmentObject(deps.navigation)
      .environmentObject(deps.nav)
      .environmentObject(deps.data)
      .environment(\.transactions, deps.transactions)
      .environment(\.realtime, deps.realtime)
      .appDatabase(deps.database)
      .environment(\.logOut, deps.logOut)
      .eraseToAnyView()

    if let rootData = deps.rootData {
      result = result.environmentObject(rootData).eraseToAnyView()
    }

    return result
  }
}
