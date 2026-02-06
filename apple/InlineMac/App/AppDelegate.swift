import AppKit
import Auth
import Combine
import InlineConfig
import InlineKit
import InlineMacUI
import Logger
import Sentry
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
  // Main Window
  private var mainWindowController: NSWindowController?

  @MainActor private let dockBadgeService = DockBadgeService()

  // Common Dependencies
  @MainActor private var dependencies = AppDependencies()

  @MainActor private var globalFocusHotkeyController: GlobalFocusHotkeyController?

  private let launchAtLoginController = LaunchAtLoginController()

#if SPARKLE
  private var updateController: UpdateController?
#endif

  // --
  let notifications = NotificationsManager()
  let navigation: NavigationModel = .shared
  let log = Log.scoped("AppDelegate")

  private var cancellables = Set<AnyCancellable>()

  func applicationWillFinishLaunching(_: Notification) {
    // Disable native tabbing
    NSWindow.allowsAutomaticWindowTabbing = false

    // Disable the bug with TableView
    // https://christiantietze.de/posts/2022/11/nstableview-variable-row-heights-broken-macos-ventura-13-0/
    UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")

    // Setup Notifications Delegate
    setupNotifications()

    dependencies.logOut = logOut
  }

  func applicationDidFinishLaunching(_: Notification) {
    initializeServices()
    setupAppearanceSetting()
    setupMainWindow()
    setupMainMenu()
    setupGlobalFocusHotkey()
    setupNotificationsSoundSetting()
    launchAtLoginController.start()
#if SPARKLE
    Task { @MainActor in
      ensureUpdateController()
      updateController?.startIfNeeded()
    }
#endif
    Task { @MainActor in
      self.dockBadgeService.start()
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

#if SPARKLE
  @objc func checkForUpdates(_ sender: Any?) {
    Task { @MainActor in
      ensureUpdateController()
      updateController?.checkForUpdates()
    }
  }
#endif

#if SPARKLE
  @MainActor private func ensureUpdateController() {
    if updateController == nil {
      updateController = UpdateController(installState: dependencies.updateInstallState)
    }
  }
#endif

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated {
      dockBadgeService.prepareForTermination()
    }
    return .terminateNow
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  func applicationDidResignActive(_: Notification) {
//    Task {
//      if Auth.shared.isLoggedIn {
//        // Mark offline
//        try? await DataManager.shared.updateStatus(online: false)
//      }
//    }
  }

  func applicationDidBecomeActive(_: Notification) {
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
    let controller: NSWindowController
    if AppSettings.shared.enableNewMacUI {
      controller = MainWindowController(dependencies: dependencies)
    } else {
      controller = LegacyMainWindowController(dependencies: dependencies)
    }
    controller.showWindow(nil)
    mainWindowController = controller
  }

  /// Bring Inline to the front and ensure the main window is visible/focused.
  @MainActor func showAndFocusMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    setupMainWindow()
    mainWindowController?.window?.makeKeyAndOrderFront(nil)
  }

  @MainActor private func setupGlobalFocusHotkey() {
    if globalFocusHotkeyController == nil {
      globalFocusHotkeyController = GlobalFocusHotkeyController { [weak self] in
        guard let self else { return }
        Task { @MainActor in
          self.showAndFocusMainWindow()
        }
      }
    }

    let apply: (HotkeySettingsStore.GlobalFocusHotkey) -> Void = { [weak self] settings in
      guard let self else { return }
      self.globalFocusHotkeyController?.applyHotkey(enabled: settings.enabled, hotkey: settings.hotkey)
    }

    apply(HotkeySettingsStore.shared.globalFocusHotkey)

    HotkeySettingsStore.shared.$globalFocusHotkey
      .removeDuplicates()
      .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
      .sink { settings in
        apply(settings)
      }
      .store(in: &cancellables)
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      setupMainWindow()
    }
    return true
  }

  func application(_: NSApplication, open urls: [URL]) {
    // Handle URLs when app is already running
    for url in urls {
      log.debug("Received URL via application:open: \(url)")
      handleCustomURL(url)
    }
  }

  private func handleCustomURL(_ url: URL) {
    // Accept both inline:// and in:// schemes
    guard let scheme = url.scheme, scheme == "inline" || scheme == "in" else {
      log.warning("Received unsupported URL scheme: \(url.scheme ?? "nil")")
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
      case "integrations":
        NotificationCenter.default.post(name: .integrationCallback, object: url)
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
    Analytics.start()

    // Register for notifications
    // notifications.setup()
  }

  @MainActor private func setupNotificationsSoundSetting() {
    // Set initial sound setting
    let initialSoundEnabled = !AppSettings.shared.disableNotificationSound
    Task {
      await MacNotifications.shared.setSoundEnabled(initialSoundEnabled)
    }

    // Observe setting changes
    AppSettings.shared.$disableNotificationSound
      .sink { [weak self] disableSound in
        Task {
          await MacNotifications.shared.setSoundEnabled(!disableSound)
        }
      }
      .store(in: &cancellables)
  }

  private func setupAppearanceSetting() {
    applyAppearance(AppSettings.shared.appearance)

    AppSettings.shared.$appearance
      .removeDuplicates()
      .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
      .sink { [weak self] appearance in
        // Defer to the next run loop to avoid re-entrancy during SwiftUI updates.
        DispatchQueue.main.async {
          self?.applyAppearance(appearance)
        }
      }
      .store(in: &cancellables)
  }

  private func applyAppearance(_ appearance: AppAppearance) {
    let resolvedAppearance = appearance.nsAppearance
    if NSApp.appearance?.name != resolvedAppearance?.name {
      NSApp.appearance = resolvedAppearance
    }
    for window in NSApp.windows {
      if window.appearance?.name != resolvedAppearance?.name {
        window.appearance = resolvedAppearance
      }
    }
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
    _: NSApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    log.debug("Registered for remote notifications: \(deviceToken)")

    notifications.didRegisterForRemoteNotifications(deviceToken: deviceToken)
  }

  func application(
    _: NSApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    log.error("Failed to register for remote notifications \(error)")
  }

  func handleNotification(_ response: UNNotificationResponse) {
    log.debug("Received notification: \(response)")

    guard let userInfo = response.notification.request.content.userInfo as? [String: Any] else {
      return
    }

    let threadIdentifier = response.notification.request.content.threadIdentifier

    if let peerId = resolvePeerFromNotification(userInfo, threadIdentifier: threadIdentifier) {
      Task(priority: .userInitiated) { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        setupMainWindow()
        if let controller = self.mainWindowController as? MainWindowController {
          await controller.openChatFromNotification(peer: peerId)
        } else {
          self.dependencies.nav.open(.chat(peer: peerId))
        }
        await self.unarchiveIfNeeded(peer: peerId)
      }
    } else {
      log.warning("Failed to resolve peer from notification userInfo")
    }
  }

  func resolvePeerFromNotification(_ userInfo: [String: Any], threadIdentifier: String) -> Peer? {
    let coercedThreadId = coerceThreadId(userInfo["threadId"]) ?? coerceThreadId(threadIdentifier)
    if let isThread = userInfo["isThread"] as? Bool,
       isThread
    {
      if let threadId = coercedThreadId {
        return .thread(id: threadId)
      }
    }

    if let peerUserId = coerceInt64(userInfo["userId"]) {
      return .user(id: peerUserId)
    }

    if let threadId = coercedThreadId {
      if let chat = try? AppDatabase.shared.reader.read({ db in
        try Chat.fetchOne(db, id: threadId)
      }) {
        if let peerUserId = chat.peerUserId {
          return .user(id: peerUserId)
        }
      }
      return .thread(id: threadId)
    }

    return nil
  }

  private func coerceInt64(_ value: Any?) -> Int64? {
    if let int64 = value as? Int64 { return int64 }
    if let int = value as? Int { return Int64(int) }
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
  }

  private func coerceThreadId(_ value: Any?) -> Int64? {
    if let threadId = coerceInt64(value) { return threadId }
    if let string = value as? String {
      let normalized = string.replacingOccurrences(of: "chat_", with: "")
      return Int64(normalized)
    }
    return nil
  }

  @MainActor
  private func unarchiveIfNeeded(peer: Peer) async {
    do {
      let dialog = try await dependencies.database.reader.read { db in
        try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peer))
      }
      guard dialog?.archived == true else { return }
      try await dependencies.data.updateDialog(peerId: peer, archived: false)
    } catch {
      log.error("Failed to unarchive chat \(peer.toString())", error: error)
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

      Analytics.logout()

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
  @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
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
