import AppKit
import Auth
import InlineConfig
import InlineKit
import Logger

import Sentry
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
  // Main Window
  private var mainWindowController: MainWindowController?

  // Common Dependencies
  @MainActor private var dependencies = AppDependencies()

  // Vim-style chat navigation key monitor
  @MainActor private var globalHotkeys: GlobalHotkeys?

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
    // Register Vim-style shortcuts (Ctrl-K / Ctrl-J) for chat navigation
    Task { @MainActor in
      self.globalHotkeys = GlobalHotkeys(dependencies: self.dependencies)
    }

    // Register for URL events
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )

    // Send timezone to server

    Task {
      // delay for 2 seconds
      try? await Task.sleep(nanoseconds: 2_000_000_000)

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

  func application(_ application: NSApplication, open urls: [URL]) {
    // Handle URLs when app is already running
    for url in urls {
      log.debug("Received URL via application:open: \(url)")
      handleCustomURL(url)
    }
  }

  private func handleCustomURL(_ url: URL) {
    // Ensure we have the inline:// scheme
    guard url.scheme == "inline" else {
      log.warning("Received non-inline URL scheme: \(url.scheme ?? "nil")")
      return
    }

    Task(priority: .userInitiated) { @MainActor in
      // Bring app to foreground
      NSApp.activate(ignoringOtherApps: true)
      setupMainWindow()

      // Parse the URL path
      let pathComponents = url.pathComponents

      // Handle different URL patterns
      switch url.host {
        case "user":
          handleUserURL(pathComponents: pathComponents)
        default:
          log.warning("Unhandled URL host: \(url.host ?? "nil")")
      }
    }
  }

  @MainActor private func handleUserURL(pathComponents: [String]) {
    // Expected format: inline://user/<id>
    // pathComponents will be ["/", "<id>"]
    guard pathComponents.count >= 2,
          let userIdString = pathComponents.last,
          let userId = Int64(userIdString)
    else {
      log.error("Invalid user URL format. Expected: inline://user/<id>")
      return
    }

    log.debug("Opening chat for user ID: \(userId)")

    // Navigate to the user chat
    dependencies.nav.open(.chat(peer: .user(id: userId)))
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
    if let isThread = userInfo["isThread"] as? Bool, let threadId = userInfo["threadId"] as? Int64, isThread {
      .thread(id: threadId)
    } else if let peerUserId = userInfo["userId"] as? Int64 {
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

// MARK: - URL Scheme Handling

extension AppDelegate {
  @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
    guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
          let url = URL(string: urlString)
    else {
      log.error("Failed to parse URL from event")
      return
    }

    log.debug("Received URL: \(url)")
    handleCustomURL(url)
  }
}
