import AppKit
import Auth
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
  @MainActor private var dependencies = AppDependencies()

  // --
  let notifications = NotificationsManager()
  let navigation: NavigationModel = .shared
  let log = Log.scoped("AppDelegate")

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Disable native tabbing
    NSWindow.allowsAutomaticWindowTabbing = false

    // Disable the bug with TableView
    // https://christiantietze.de/posts/2022/11/nstableview-variable-row-heights-broken-macos-ventura-13-0/
    UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")

    // Setup Notifications Delegate
    setupNotifications()

    dependencies.logOut = logOut
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    initializeServices()
    setupMainWindow()
    setupMainMenu()

    // Send timezone to server
    Task {
      if Auth.shared.isLoggedIn {
        try? await DataManager.shared.updateTimezone()
      }
    }
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  func applicationDidResignActive(_ notification: Notification) {
//    Task {
//      if Auth.shared.isLoggedIn {
//        // Mark offline
//        try? await DataManager.shared.updateStatus(online: false)
//      }
//    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
//    Task {
//      if Auth.shared.isLoggedIn {
//        // Mark online
//        try? await DataManager.shared.updateStatus(online: true)
//      }
//    }
  }

  @MainActor private func setupMainWindow() {
    // If window controller exists but window is closed
    if let windowController = mainWindowController {
      windowController.showWindow(nil)
      windowController.window?.makeKeyAndOrderFront(nil)
      return
    }

    // Create new window controller if it doesn't exist
    let controller = MainWindowController(dependencies: dependencies)
    controller.showWindow(nil)
    mainWindowController = controller
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      setupMainWindow()
    }
    return true
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

    guard let userInfo = response.notification.request.content.userInfo as? [String: Any] else {
      return
    }

    if let peerId = getPeerFromNotification(userInfo) {
      Task(priority: .userInitiated) { @MainActor in
        dependencies.nav.open(.chat(peer: peerId))

        // TODO: Handle notification from threads/space chats
      }
    }
  }

  func getPeerFromNotification(_ userInfo: [String: Any]) -> Peer? {
    if let peerUserId = userInfo["userId"] as? Int64 {
      .user(id: peerUserId)
    } else {
      nil
    }
  }

  @MainActor private func setupMainMenu() {
    AppMenu.shared.setupMainMenu(dependencies: dependencies)
  }

  private func logOut() async {
    // Navigate outside of the app
    DispatchQueue.main.async {
      self.dependencies.viewModel.navigate(.onboarding)

      // Reset internal navigation
      self.dependencies.navigation.reset()
      self.dependencies.nav.reset()
    }

    Task {
      _ = try? await ApiClient.shared.logout()

      // Clear database
      try? AppDatabase.loggedOut()

      // Clear creds
      await Auth.shared.logOut()

      // Clear transactions
      Transactions.shared.clearAll()

      // Stop WebSocket
      await dependencies.realtime.loggedOut()
    }
  }
}

// MARK: - Dependency Container

@MainActor
struct AppDependencies {
  let auth = Auth.shared
  let viewModel = MainWindowViewModel()
  let overlay = OverlayManager()
  let navigation = NavigationModel.shared
  let transactions = Transactions.shared
  let realtime = Realtime.shared
  let database = AppDatabase.shared
  let data = DataManager(database: AppDatabase.shared)

  // Per window
  let nav: Nav = .main
  var keyMonitor: KeyMonitor?

  // Optional
  var rootData: RootData?
  var logOut: (() async -> Void) = {}
  // Per window nav?
  // var nav =
}

extension View {
  func environment(dependencies deps: AppDependencies) -> AnyView {
    var result = environment(\.auth, deps.auth)
      .environmentObject(deps.viewModel)
      .environmentObject(deps.overlay)
      .environmentObject(deps.navigation)
      .environmentObject(deps.nav)
      .environmentObject(deps.data)
      .environment(\.transactions, deps.transactions)
      .environment(\.realtime, deps.realtime)
      .appDatabase(deps.database)
      .environment(\.logOut, deps.logOut)
      .environment(\.keyMonitor, deps.keyMonitor)
      .eraseToAnyView()

    if let rootData = deps.rootData {
      result = result.environmentObject(rootData).eraseToAnyView()
    }

    return result
  }
}
