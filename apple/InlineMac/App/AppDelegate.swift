import AppKit
import Auth
import Combine
import InlineConfig
import InlineKit
import InlineMacUI
import Logger
import MacDevtools
import RealtimeV2
import Sentry
import SwiftUI
import UserNotifications

#if DEVBUILD_REQUIRES_SCRIPT && !DEBUG_BUILD
  #error("DevBuild must be built through scripts/macos/build-local-app.sh or macOS release scripts.")
#endif

class AppDelegate: NSObject, NSApplicationDelegate {
  private static let customURLSchemes: Set<String> = ["inline", "inline-dev", "inline-debug", "in"]

  private var didHandleInitialActivation = false

  @MainActor private let appBridge = AppBridge(app: NSApp)
  @MainActor private let dockBadgeService = DockBadgeService()

  // Common Dependencies
  @MainActor private(set) lazy var dependencies: AppDependencies = {
    var deps = AppDependencies(appBridge: appBridge)
    deps.logOut = { [weak self] in
      guard let self else { return }
      await self.performLogOut()
    }
    return deps
  }()

  @MainActor private var globalFocusHotkeyController: GlobalFocusHotkeyController?

  private let installLocationPrompt = AppInstallLocationPrompt()
  private let launchAtLoginController = LaunchAtLoginController()

#if SPARKLE
  private var updateController: UpdateController?
#endif

  // --
  let notifications = NotificationsManager()
  let log = Log.scoped("AppDelegate")

  private var cancellables = Set<AnyCancellable>()
  // Session-scoped guard: show the realtime connection failure alert at most once per app run.
  private var didShowRealtimeConnectionFailureAlert = false

  func applicationWillFinishLaunching(_: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = true

    MacDevtools.bootstrap()
    registerMacGlobalSettings()

    // Setup Notifications Delegate
    setupNotifications()

    _ = dependencies
  }

  func applicationDidFinishLaunching(_: Notification) {
    initializeServices()
    setupAppearanceSetting()
    setupMainMenu()
    presentInstallLocationPromptIfNeeded()
    registerMainWindowCoordinator()
    setupRealtimeConnectionFailureObserver()
    setupRealtimeAuthInvalidatedObserver()
    setupGlobalFocusHotkey()
    setupNotificationsSoundSetting()
    launchAtLoginController.start()
    TimezoneManager.shared.start()
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
  }

  @MainActor
  @objc func openNewMainWindow(_ sender: Any?) {
    MainWindowController.newWindow(dependencies: dependencies, sender: sender)
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
    if !didHandleInitialActivation {
      didHandleInitialActivation = true
      if MainWindowController.all.isEmpty {
        setupMainWindow()
      }
      refetchSessionAfterActivationIfNeeded()
      return
    }

    restoreMainWindowAfterActivationIfNeeded()
    refetchSessionAfterActivationIfNeeded()
  }

  private func registerMacGlobalSettings() {
    UserDefaults.standard.register(defaults: [
      // NSTableView row-height estimation is broken for variable-height rows on AppKit.
      // Keep this off so message list layout stays stable.
      "NSTableViewCanEstimateRowHeights": false,

      // Disable macOS SMS one-time-code autofill heuristics inside Inline inputs.
      "NSAutoFillHeuristicControllerEnabled": false,

      "showSidebarMessagePreview": true,
      "includeSpaceChatsInHomeSidebar": true,
      ExperimentalFeatureFlags.voiceMessagesKey: false,
      ExperimentalFeatureFlags.sidebarAsInboxKey: true,
    ])
  }

  @discardableResult
  @MainActor private func setupMainWindow() -> MainWindowController {
    MainWindowController.showDefault(dependencies: dependencies)
  }

  /// CMD+Tab can activate the app without triggering `applicationShouldHandleReopen`.
  /// If we become active with no visible windows, restore the main window.
  @MainActor private func restoreMainWindowAfterActivationIfNeeded() {
    let hasVisibleWindows = NSApp.windows.contains { window in
      window.isVisible && !window.isMiniaturized
    }
    guard !hasVisibleWindows else { return }

    setupMainWindow()
  }

  @MainActor private func refetchSessionAfterActivationIfNeeded() {
    guard dependencies.viewModel.topLevelRoute == .main else { return }
    dependencies.session.refetchChats(dependencies: dependencies)
  }

  /// Bring Inline to the front and ensure the main window exists.
  @MainActor func showAndFocusMainWindow() {
    let app = NSRunningApplication.current
    if app.isHidden {
      _ = app.unhide()
    }
    NSApp.activate(ignoringOtherApps: true)
    NSApp.arrangeInFront(nil)
    setupMainWindow()
  }

  /// Global hotkey should act as an app-level toggle: show when backgrounded, hide when foregrounded.
  /// Keep this simple and rely on AppKit to restore focus.
  @MainActor func toggleAppFromGlobalHotkey() {
    let app = NSRunningApplication.current
    if app.isActive {
      _ = app.hide()
      return
    }
    showAndFocusMainWindow()
  }

  @MainActor private func setupGlobalFocusHotkey() {
    if globalFocusHotkeyController == nil {
      globalFocusHotkeyController = GlobalFocusHotkeyController { [weak self] in
        guard let self else { return }
        self.toggleAppFromGlobalHotkey()
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
      showAndFocusMainWindow()
      return false
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
    guard let scheme = url.scheme?.lowercased(), Self.customURLSchemes.contains(scheme) else {
      log.warning("Received unsupported URL scheme: \(url.scheme ?? "nil")")
      return
    }

    Task(priority: .userInitiated) { @MainActor in
      // Bring app to foreground
      NSApp.activate(ignoringOtherApps: true)
      setupMainWindow()

      // Handle different URL patterns
      switch url.host?.lowercased() {
      case "user":
        handleUserURL(url)
      case "chat", "thread":
        handleChatURL(url)
      case "integrations":
        showAndFocusMainWindow()
        NotificationCenter.default.post(name: .integrationCallback, object: url)
      default:
        log.warning("Unhandled URL host: \(url.host ?? "nil")")
      }
    }
  }

  @MainActor private func handleUserURL(_ url: URL) {
    guard let userId = inlineUserId(from: url) else {
      log.error("Invalid user URL format. Expected: inline://user/<id> or inline://user?id=<id>")
      return
    }

    log.debug("Opening chat for user ID: \(userId)")

    // Navigate to the user chat
    let peer: Peer = .user(id: userId)
    openChat(peer: peer)
  }

  @MainActor private func handleChatURL(_ url: URL) {
    guard let chatId = inlineChatId(from: url) else {
      log.error(
        "Invalid chat URL format. Expected: inline://chat/<id>, inline://chat?id=<id>, inline://thread/<id>, or inline://thread?id=<id>"
      )
      return
    }

    log.debug("Opening chat for ID: \(chatId)")

    openChat(peer: .thread(id: chatId))
  }

  private func inlineUserId(from url: URL) -> Int64? {
    guard Self.isInlineURL(url, host: "user") else {
      return nil
    }

    return inlineId(from: url, queryNames: ["id", "user_id"])
  }

  private func inlineChatId(from url: URL) -> Int64? {
    guard Self.isInlineURL(url), let host = url.host?.lowercased(), host == "chat" || host == "thread" else {
      return nil
    }

    return inlineId(from: url, queryNames: ["id", "chat_id"])
  }

  private static func isInlineURL(_ url: URL, host: String? = nil) -> Bool {
    guard let scheme = url.scheme?.lowercased(), customURLSchemes.contains(scheme) else {
      return false
    }
    guard let host else { return true }
    return url.host?.lowercased() == host
  }

  private func inlineId(from url: URL, queryNames: Set<String>) -> Int64? {
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      let queryId = components.queryItems?.first { queryNames.contains($0.name.lowercased()) }?.value
      if let id = positiveId(queryId) {
        return id
      }
    }

    let pathId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return positiveId(pathId)
  }

  private func positiveId(_ value: String?) -> Int64? {
    guard let value, !value.isEmpty, value.allSatisfy(\.isNumber), let id = Int64(value), id > 0 else {
      return nil
    }
    return id
  }

  @MainActor private func openChat(peer: Peer) {
    guard Auth.shared.getIsLoggedIn(), dependencies.viewModel.topLevelRoute == .main else {
      MainWindowOpenCoordinator.shared.openOnboarding()
      return
    }

    setupMainWindow().route(.chat(peer: peer))
  }

  @MainActor private func registerMainWindowCoordinator() {
    MainWindowOpenCoordinator.shared.register(
      openMainWindow: { [weak self] in
        Task { @MainActor in
          self?.openMainWindowFromCoordinator()
        }
      },
      openOnboardingWindow: { [weak self] in
        Task { @MainActor in
          self?.showOnboardingWindow()
        }
      }
    )
  }

  @MainActor private func openMainWindowFromCoordinator() {
    let destination = MainWindowOpenCoordinator.shared.consumePendingDestination()
    if let destination {
      MainWindowController.newWindow(dependencies: dependencies, destination: destination)
      return
    }

    setupMainWindow()
  }

  @MainActor private func showOnboardingWindow() {
    dependencies.viewModel.navigate(.onboarding)
    showAndFocusMainWindow()
  }

  @MainActor
  func clearCacheAndResetApp() async throws {
    let restoreRoute = TopLevelRoute.initial(for: Auth.shared.getStatus())

    dependencies.session.reset()
    dependencies.viewModel.navigate(.loading)
    MainWindowController.resetAllNavigation()

    await Task.yield()

    do {
      await Api.realtime.clearSyncState()
      Transactions.shared.clearAll()
      ObjectCache.shared.clear()
      try await FileCache.shared.clearCache()
      try AppDatabase.clearDB()
    } catch {
      dependencies.viewModel.navigate(restoreRoute)
      throw error
    }

    dependencies.navigation.reset()
    dependencies.nav.reset()

    MainWindowController.closeAll()
    MainWindowOpenCoordinator.shared.resetWindows()

    dependencies.viewModel.navigate(restoreRoute)
    setupMainWindow()
  }

  private func initializeServices() {
    // Setup Sentry
    Analytics.start()

    // Register for notifications
    // notifications.setup()
  }

  private func setupRealtimeConnectionFailureObserver() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRealtimeConnectionFailureNotification),
      name: .realtimeV2ConnectionInitFailed,
      object: nil
    )
  }

  private func setupRealtimeAuthInvalidatedObserver() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRealtimeAuthInvalidatedNotification),
      name: .realtimeV2AuthInvalidated,
      object: nil
    )
  }

  @objc private func handleRealtimeAuthInvalidatedNotification() {
    Task { [weak self] in
      await self?.performLogOut(notifyServer: false)
    }
  }

  @objc private func handleRealtimeConnectionFailureNotification() {
    Task { @MainActor [weak self] in
      self?.presentRealtimeConnectionFailureAlertIfNeeded()
    }
  }

  @MainActor private func presentRealtimeConnectionFailureAlertIfNeeded() {
    guard !didShowRealtimeConnectionFailureAlert else { return }
    didShowRealtimeConnectionFailureAlert = true

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Connection Error"

#if SPARKLE
    if shouldShowRestartAction {
      alert.informativeText = "Inline couldn't complete a secure connection to your account. Please restart the app."
      alert.addButton(withTitle: "Restart Inline")
      alert.addButton(withTitle: "Close")
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        restartApplication()
      }
    } else {
      alert.informativeText = "Inline couldn't complete a secure connection to your account. Please restart the app manually."
      alert.addButton(withTitle: "Close")
      _ = alert.runModal()
    }
#else
    alert.informativeText = "Inline couldn't complete a secure connection to your account. Please restart the app."
    alert.addButton(withTitle: "Close")
    _ = alert.runModal()
#endif
  }

#if SPARKLE
  private var shouldShowRestartAction: Bool {
    !isSandboxedRuntime
  }

  private var isSandboxedRuntime: Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  }
#endif

  @MainActor private func presentInstallLocationPromptIfNeeded() {
    installLocationPrompt.presentIfNeeded { [weak self] appURL in
      self?.restartApplication(at: appURL)
    }
  }

  @MainActor private func restartApplication(at appURL: URL = Bundle.main.bundleURL) {
    let log = self.log
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
      if let error {
        log.error("Failed to relaunch app", error: error)
        return
      }
      Task { @MainActor in
        NSApp.terminate(nil)
      }
    }
  }

  @MainActor private func setupNotificationsSoundSetting() {
    // Set initial sound setting
    let initialSoundEnabled = !AppSettings.shared.disableNotificationSound
    Task {
      await MacNotifications.shared.setSoundEnabled(initialSoundEnabled)
    }

    // Observe setting changes
    AppSettings.shared.$disableNotificationSound
      .sink { disableSound in
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

  func handleNotification(_ response: UNNotificationResponse) {
    log.debug("Received notification: \(response)")

    guard let userInfo = response.notification.request.content.userInfo as? [String: Any] else {
      return
    }

    let threadIdentifier = response.notification.request.content.threadIdentifier

    if let peerId = resolvePeerFromNotification(userInfo, threadIdentifier: threadIdentifier) {
      Task(priority: .userInitiated) { @MainActor in
        self.openChat(peer: peerId)
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

  @MainActor
  func performLogOut(notifyServer: Bool = true) async {
    // Navigate outside of the app
    dependencies.viewModel.navigate(.onboarding)

    // Reset internal navigation
    dependencies.navigation.reset()
    dependencies.nav.reset()

    MainWindowOpenCoordinator.shared.openOnboarding()

    if notifyServer {
      _ = try? await ApiClient.shared.logout()
    }

    Analytics.logout()

    // Clear database
    try? AppDatabase.loggedOut()

    // Clear creds
    await Auth.shared.logOut()

    // Clear transactions
    Transactions.shared.clearAll()
    ObjectCache.shared.clear()
    dependencies.session.reset()

    // Stop WebSocket
    await dependencies.realtime.loggedOut()
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
