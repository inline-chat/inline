import AppKit
import Auth
import Combine
import Darwin
import InlineConfig
import InlineKit
import InlineMacUI
import Logger
import MacDevtools
import MacTheme
import RealtimeV2
import Sentry
import SwiftUI
import UserNotifications

#if DEVBUILD_REQUIRES_SCRIPT && !DEBUG_BUILD
  #error("DevBuild must be built through scripts/macos/build-local-app.sh or macOS release scripts.")
#endif

private final class ApplicationTerminationGate: @unchecked Sendable {
  private let lock = NSLock()
  // The lock protects every access to this otherwise task-shared bit.
  private var isClaimed = false

  func claim() -> Bool {
    lock.withLock {
      guard !isClaimed else { return false }
      isClaimed = true
      return true
    }
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  private static var customURLSchemes: Set<String> { InlineDeepLink.currentAppSchemes }

  private var didHandleInitialActivation = false

  @MainActor private let appBridge = AppBridge(app: NSApp)
  @MainActor private lazy var dockBadgeService = DockBadgeService(unreadCounts: dependencies.unreadCounts)

  // Common Dependencies
  @MainActor private(set) lazy var dependencies: AppDependencies = {
    var deps = AppDependencies(appBridge: appBridge)
    deps.logOut = { [weak self] in
      guard let self else { return }
      await self.performLogOut()
    }
    return deps
  }()

  @MainActor private var globalHotkeyController: GlobalHotkeyController?
  @MainActor private var terminationTask: Task<Void, Never>?
  @MainActor private var isLoggingOut = false
  @MainActor private var pendingSpaceJoin: SpaceJoinReference?
  @MainActor private var spaceJoinTask: Task<Void, Never>?
  @MainActor private var spaceJoinGeneration: UInt64 = 0

  private let installLocationPrompt = AppInstallLocationPrompt()
  @MainActor private let launchAtLoginController = LaunchAtLoginController()

  // --
  let notifications = NotificationsManager()
  let log = Log.scoped("AppDelegate")

  private var cancellables = Set<AnyCancellable>()
  // Session-scoped guard: show the realtime connection failure alert at most once per app run.
  private var didShowRealtimeConnectionFailureAlert = false

  func applicationWillFinishLaunching(_: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = true

    // Freeze the chat font before any message layout or settings UI is created.
    _ = ChatTypography.current

    MacDevtools.bootstrap()
    registerMacGlobalSettings()

    // Setup Notifications Delegate
    setupNotifications()

    _ = dependencies
  }

  func applicationDidFinishLaunching(_: Notification) {
    initializeServices()
    setupAppearanceSetting()
    setupThemeSetting()
    setupMainMenu()
    Task { @MainActor in
      await dependencies.cliInstaller.refresh()
    }
    presentInstallLocationPromptIfNeeded()
    registerMainWindowCoordinator()
    setupRealtimeConnectionFailureObserver()
    setupRealtimeAuthInvalidatedObserver()
    dependencies.viewModel.$topLevelRoute
      .receive(on: RunLoop.main)
      .sink { [weak self] route in
        guard route == .main else { return }
        Task { @MainActor in
          self?.resumePendingSpaceJoin()
        }
      }
      .store(in: &cancellables)
    setupGlobalHotkeys()
    setupNotificationsSoundSetting()
    launchAtLoginController.start()
    TimezoneManager.shared.start()
#if SPARKLE
    Task { @MainActor in
      dependencies.updates.start()
    }
#endif
    Task { @MainActor in
      self.dependencies.unreadCounts.start()
      self.dockBadgeService.start()
    }
    Task { @MainActor [weak self] in
      guard await Auth.shared.hasPendingLogout() else { return }
      await self?.performLogOut(notifyServer: false)
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

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated { () -> NSApplication.TerminateReply in
      guard terminationTask == nil else { return .terminateLater }

      let terminationGate = ApplicationTerminationGate()
      Task.detached(priority: .userInitiated) {
        try? await Task.sleep(for: .seconds(3))
        guard terminationGate.claim() else { return }

        // Ordinary exit previously crashed in static finalizers while SQLCipher work was active.
        Darwin._exit(EXIT_SUCCESS)
      }

      dockBadgeService.prepareForTermination()
      CLIInstallerWindowController.prepareForApplicationTermination()
      AgentSetupWindowController.prepareForApplicationTermination()
      dependencies.session.reset()
      Drafts2.shared.flushBlocking()

      let realtime = dependencies.realtimeV2
      let database = dependencies.database
      terminationTask = Task { @MainActor in
        await realtime.prepareForTermination()

        let databaseCloseTask = Task.detached(priority: .userInitiated) {
          try database.closePersistentStorage()
        }
        do {
          try await databaseCloseTask.value
        } catch {
          log.error("Database did not close cleanly during application termination", error: error)
        }

        guard terminationGate.claim() else { return }

        // Start before replying so it can also break a hang inside AppKit's final termination path.
        Task.detached(priority: .userInitiated) {
          try? await Task.sleep(for: .seconds(2))
          Darwin._exit(EXIT_SUCCESS)
        }
        sender.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
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
    Task { @MainActor [weak self] in
      guard Auth.shared.isLoggedIn else { return }
      await self?.dependencies.gridRuntime.applicationDidWake()
    }

    if !didHandleInitialActivation {
      didHandleInitialActivation = true
      if MainWindowController.all.isEmpty {
        setupMainWindow()
      }
      return
    }

    restoreMainWindowAfterActivationIfNeeded()
  }

  private func registerMacGlobalSettings() {
    UserDefaults.standard.register(defaults: [
      // NSTableView row-height estimation is broken for variable-height rows on AppKit.
      // Keep this off so message list layout stays stable.
      "NSTableViewCanEstimateRowHeights": false,

      // Keep macOS autofill heuristics enabled so email login codes can be offered from Mail.

      "showSidebarMessagePreview": true,
      "includeSpaceChatsInHomeSidebar": true,
      AppSettings.sidebarItemSizeKey: SidebarItemSize.standard.rawValue,
      AppSettings.sidebarModeKey: SidebarMode.inbox.rawValue,
      AppSettings.sidebarSortKey: SidebarSortMode.openedOrder.rawValue,
      AppSettings.sidebarCleanupIntervalKey: SidebarCleanupInterval.defaultValue.rawValue,
      AppSettings.messageDoubleClickActionKey: MessageGestureAction.defaultDoubleClick.rawValue,
      AppSettings.messageHoldActionKey: MessageGestureAction.defaultHold.rawValue,
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

  @MainActor private func setupGlobalHotkeys() {
    if globalHotkeyController == nil {
      globalHotkeyController = GlobalHotkeyController()
    }

    let applyFocus: (HotkeySettingsStore.HotkeyConfiguration) -> Void = { [weak self] settings in
      guard let self else { return }
      self.globalHotkeyController?.applyHotkey(
        action: .focusInline,
        enabled: settings.enabled,
        hotkey: settings.hotkey,
        onPress: { [weak self] in self?.toggleAppFromGlobalHotkey() }
      )
    }

    let applyGridMicrophone: (HotkeySettingsStore.HotkeyConfiguration) -> Void = { [weak self] settings in
      guard let self else { return }
      self.globalHotkeyController?.applyHotkey(
        action: .gridMicrophone,
        enabled: settings.enabled,
        hotkey: settings.hotkey,
        onPress: { [weak self] in self?.dependencies.grid.toggleCurrentMicrophone() }
      )
    }

    applyFocus(HotkeySettingsStore.shared.globalFocusHotkey)
    applyGridMicrophone(HotkeySettingsStore.shared.gridMicrophoneHotkey)

    HotkeySettingsStore.shared.$globalFocusHotkey
      .removeDuplicates()
      .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
      .sink { settings in
        applyFocus(settings)
      }
      .store(in: &cancellables)

    HotkeySettingsStore.shared.$gridMicrophoneHotkey
      .removeDuplicates()
      .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
      .sink { settings in
        applyGridMicrophone(settings)
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
      if Self.isCLIAuthURL(url) {
        log.debug("Received local CLI auth request via application:open")
      } else if ProviderSignInCoordinator.shared.canHandle(url) {
        log.debug("Received provider auth callback via application:open")
      } else if url.host?.lowercased() == "join" {
        log.debug("Received space join URL via application:open")
      } else {
        log.debug("Received URL via application:open: \(url)")
      }
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
      case "auth" where ProviderSignInCoordinator.shared.canHandle(url):
        await ProviderSignInCoordinator.shared.handleCallback(url)
      case "cli-auth":
        await handleCLIAuthURL(url)
      case "user":
        handleUserURL(url)
      case "chat", "thread":
        await handleChatURL(url)
      case "join":
        handleSpaceJoinURL(url)
      case "integrations":
        dependencies.appBridge.openSettings(
          dependencies: dependencies,
          selectedCategory: .connectors
        )
        DispatchQueue.main.async {
          NotificationCenter.default.post(name: .connectorOAuthCallback, object: url)
          NotificationCenter.default.post(name: .integrationCallback, object: url)
        }
      default:
        log.warning("Unhandled URL host: \(url.host ?? "nil")")
      }
    }
  }

  @MainActor private func handleCLIAuthURL(_ url: URL) async {
    guard let endpoint = LocalCLIAuthBroker.Endpoint(url: url) else {
      presentCLIAuthAlert(
        title: "Invalid CLI sign-in request",
        message: "Inline could not verify this local sign-in request. Start login again from the Inline CLI."
      )
      return
    }

    guard Auth.shared.getIsLoggedIn(), dependencies.viewModel.topLevelRoute == .main else {
      await LocalCLIAuthBroker.cancel(endpoint, detail: "Inline for Mac is not signed in.")
      presentCLIAuthAlert(
        title: "Sign in to Inline first",
        message: "Sign in to Inline for Mac, then start CLI login again."
      )
      return
    }

    do {
      let client = try await LocalCLIAuthBroker.probe(endpoint)
      guard approveCLIAuth(client) else {
        await LocalCLIAuthBroker.cancel(endpoint, detail: "The request was declined in Inline for Mac.")
        return
      }

      _ = try await LocalCLIAuthBroker.createAndDeliverSession(
        endpoint,
        client: client,
        realtime: dependencies.realtimeV2
      )
    } catch {
      await LocalCLIAuthBroker.cancel(endpoint, detail: "Inline for Mac could not complete the request.")
      log.error("Local CLI auth handoff failed: \(error.localizedDescription)")
      presentCLIAuthAlert(
        title: "Could not sign in to the CLI",
        message: "\(error.localizedDescription) Start login again from the Inline CLI."
      )
    }
  }

  @MainActor private func approveCLIAuth(_ client: LocalCLIAuthBroker.ClientMetadata) -> Bool {
    let deviceName = client.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? "this Mac"
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Allow Inline CLI to sign in?"
    alert.informativeText = "A CLI on \(displayName) is requesting access. Verify that the CLI shows code \(client.verificationCode)."
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  @MainActor private func presentCLIAuthAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
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

  @MainActor private func handleChatURL(_ url: URL) async {
    guard let target = inlineChatTarget(from: url) else {
      log.error(
        "Invalid chat URL format. Expected a chat link or chat/message link."
      )
      return
    }

    guard Auth.shared.getIsLoggedIn(), dependencies.viewModel.topLevelRoute == .main else {
      MainWindowOpenCoordinator.shared.openOnboarding()
      return
    }

    guard let peer = await dependencies.resolveChatLinkPeer(
      chatId: target.chatId,
      targetMessageId: target.messageId
    ) else {
      ToastCenter.shared.showError("Couldn’t open chat link")
      return
    }

    openChat(peer: peer, targetMessageId: target.messageId)
  }

  @MainActor private func handleSpaceJoinURL(_ url: URL) {
    guard let deepLink = InlineDeepLink(url: url, supportedSchemes: Self.customURLSchemes),
          let reference = SpaceJoinReference(deepLink: deepLink)
    else {
      ToastCenter.shared.showError("This invite is invalid, expired, or unavailable.")
      return
    }

    spaceJoinGeneration &+= 1
    spaceJoinTask?.cancel()
    spaceJoinTask = nil
    pendingSpaceJoin = reference

    guard Auth.shared.getIsLoggedIn(), dependencies.viewModel.topLevelRoute == .main else {
      MainWindowOpenCoordinator.shared.openOnboarding()
      return
    }
    resumePendingSpaceJoin()
  }

  @MainActor private func resumePendingSpaceJoin() {
    guard Auth.shared.getIsLoggedIn(),
          dependencies.viewModel.topLevelRoute == .main,
          let reference = pendingSpaceJoin,
          spaceJoinTask == nil
    else { return }

    let generation = spaceJoinGeneration
    spaceJoinTask = Task { @MainActor [weak self] in
      defer {
        if self?.spaceJoinGeneration == generation {
          self?.spaceJoinTask = nil
        }
      }
      do {
        let spaceID = try await SpaceJoiner.join(reference)
        guard !Task.isCancelled, self?.spaceJoinGeneration == generation else { return }
        self?.pendingSpaceJoin = nil
        self?.setupMainWindow().openSpace(spaceID)
      } catch is CancellationError {
        return
      } catch {
        guard self?.spaceJoinGeneration == generation else { return }
        self?.pendingSpaceJoin = nil
        ToastCenter.shared.showError("This invite is invalid, expired, or unavailable.")
      }
    }
  }

  @MainActor private func cancelPendingSpaceJoin() {
    spaceJoinGeneration &+= 1
    spaceJoinTask?.cancel()
    spaceJoinTask = nil
    pendingSpaceJoin = nil
  }

  private func inlineUserId(from url: URL) -> Int64? {
    guard Self.isInlineURL(url, host: "user") else {
      return nil
    }

    return inlineId(from: url, queryNames: ["id", "user_id"])
  }

  private func inlineChatTarget(from url: URL) -> (chatId: Int64, messageId: Int64?)? {
    guard let deepLink = InlineDeepLink(url: url, supportedSchemes: Self.customURLSchemes) else {
      return nil
    }

    switch deepLink {
    case let .chat(id):
      return (chatId: id, messageId: nil)
    case let .message(chatId, messageId):
      return (chatId: chatId, messageId: messageId)
    case .user, .publicSpace, .spaceInvite:
      return nil
    }
  }

  private static func isInlineURL(_ url: URL, host: String? = nil) -> Bool {
    guard let scheme = url.scheme?.lowercased(), customURLSchemes.contains(scheme) else {
      return false
    }
    guard let host else { return true }
    return url.host?.lowercased() == host
  }

  private static func isCLIAuthURL(_ url: URL) -> Bool {
    isInlineURL(url, host: "cli-auth")
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

  @MainActor private func openChat(peer: Peer, targetMessageId: Int64? = nil) {
    guard Auth.shared.getIsLoggedIn(), dependencies.viewModel.topLevelRoute == .main else {
      MainWindowOpenCoordinator.shared.openOnboarding()
      return
    }

    let mainWindow = setupMainWindow()
    if let targetMessageId {
      mainWindow.openChat(peer: peer, targetMessageId: targetMessageId)
    } else {
      mainWindow.route(.chat(peer: peer))
    }
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
  func resetLocalDataAndReload() async throws {
    let restoreRoute = TopLevelRoute.initial(for: Auth.shared.getStatus())

    dependencies.session.reset()
    dependencies.viewModel.navigate(.loading)
    MainWindowController.resetAllNavigation()

    await Task.yield()

    do {
      await Api.realtime.loggedOut()
      await dependencies.realtime.loggedOut()
      await FileUploader.shared.cancelAll()
      await FileCache.shared.cancelAllDownloads()
      await FileDownloader.shared.resetSession()
      NotionTaskService.shared.resetSession()
      await Drafts2.shared.resetForAccountChange()
      await QuickSearchUsageStore.shared.clearCurrentAccount()
      await Transactions.shared.clearAllAndWait()
      ObjectCache.shared.clear()
      try await FileCache.shared.clearCache()
      await dependencies.commandBarCatalog.reset()
      try AppDatabase.clearDB()
    } catch {
      await Api.realtime.resumeAfterLocalDataReset()
      await dependencies.realtime.start()
      dependencies.viewModel.navigate(restoreRoute)
      throw error
    }

    await Api.realtime.resumeAfterLocalDataReset()
    await dependencies.realtime.start()
    dependencies.appUndo.clear()

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

  private func setupThemeSetting() {
    applyTheme()

    AppSettings.shared.$themeRevision
      .dropFirst()
      .removeDuplicates()
      .debounce(for: .milliseconds(33), scheduler: RunLoop.main)
      .sink { [weak self] _ in
        self?.applyTheme()
      }
      .store(in: &cancellables)
  }

  private func applyTheme() {
    for window in NSApp.windows {
      if window.windowController is MainWindowController {
        window.backgroundColor = Theme.windowContentBackgroundColor
      } else if window.windowController is SettingsWindowController {
        window.backgroundColor = Theme.settingsWindowBackgroundColor
      }
      if let contentView = window.contentView {
        invalidateTheme(in: contentView)
      }
      window.invalidateShadow()
    }
  }

  private func invalidateTheme(in view: NSView) {
    if let refreshableView = view as? AppThemeRefreshable {
      refreshableView.refreshAppTheme()
    }
    view.needsDisplay = true
    view.layer?.setNeedsDisplay()
    for subview in view.subviews {
      invalidateTheme(in: subview)
    }
  }

  private func applyAppearance(_ appearance: AppAppearance) {
    let resolvedAppearance = appearance.nsAppearance
    if NSApp.appearance?.name != resolvedAppearance?.name {
      NSApp.appearance = resolvedAppearance
    }
    for window in NSApp.windows where window.appearance?.name != resolvedAppearance?.name {
      window.appearance = resolvedAppearance
    }
    applyTheme()
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

    if handleGridScreenShareNotification(userInfo) {
      return
    } else if let peerId = resolvePeerFromNotification(userInfo, threadIdentifier: threadIdentifier) {
      Task(priority: .userInitiated) { @MainActor in
        self.openChat(peer: peerId)
        await self.unarchiveIfNeeded(peer: peerId)
      }
    } else {
      log.warning("Failed to resolve peer from notification userInfo")
    }
  }

  private func handleGridScreenShareNotification(_ userInfo: [String: Any]) -> Bool {
    guard userInfo["type"] as? String == "gridScreenShare",
          let spaceID = coerceInt64(userInfo["spaceId"]),
          let roomID = coerceInt64(userInfo["roomId"]),
          let userID = coerceInt64(userInfo["userId"]),
          let participantIdentity = userInfo["participantIdentity"] as? String,
          let event = userInfo["event"] as? String,
          event == "started" || event == "stopped"
    else { return false }

    Task { @MainActor in
      MainWindowOpenCoordinator.shared.openWindow(.grid(spaceID: spaceID))
      if event == "started" {
        dependencies.grid.openScreenShareFromNotification(
          spaceID: spaceID,
          roomID: roomID,
          userID: userID,
          participantIdentity: participantIdentity
        )
      }
    }
    return true
  }

  func resolvePeerFromNotification(_ userInfo: [String: Any], threadIdentifier: String) -> Peer? {
    let coercedThreadId = coerceThreadId(userInfo["threadId"]) ?? coerceThreadId(threadIdentifier)
    if let isThread = userInfo["isThread"] as? Bool,
       isThread {
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
    guard !isLoggingOut else { return }
    isLoggingOut = true
    defer {
      LoggingOutWindowController.dismiss()
      isLoggingOut = false
    }

    let mediaShutdown = await dependencies.gridRuntime.prepareForLogout()
    guard mediaShutdown.isLocallyQuiescent else {
      log.error(
        "Logout stopped because Grid local media shutdown could not be proven: active_rooms=\(mediaShutdown.locallyActiveRoomCount) rtc_media_mutations=\(mediaShutdown.rtcLocalMediaMutationCount) microphone_publications=\(mediaShutdown.microphonePublicationCount) screen_publications=\(mediaShutdown.screenSharePublicationCount) failures=\(mediaShutdown.failures.joined(separator: ", "))"
      )
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "Inline could not safely stop Grid audio"
      alert.informativeText =
        "Logout was cancelled because microphone or playback shutdown could not be verified. Please leave Grid and try again."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }

    cancelPendingSpaceJoin()
    await Auth.shared.beginLogout()
    LoggingOutWindowController.show()
    await Task.yield()

    if notifyServer {
      await notifyServerLogout()
    }

    Analytics.logout()

    // Stop every account-owned producer before clearing credentials or the database.
    await Api.realtime.loggedOut()
    await dependencies.realtime.loggedOut()
    await FileUploader.shared.cancelAll()
    await FileCache.shared.cancelAllDownloads()
    await FileDownloader.shared.resetSession()
    NotionTaskService.shared.resetSession()
    await Drafts2.shared.resetForAccountChange()

    await QuickSearchUsageStore.shared.clearCurrentAccount()
    await dependencies.commandBarCatalog.reset()

    await Transactions.shared.clearAllAndWait()
    ObjectCache.shared.clear()
    dependencies.session.reset()

    do {
      try await AppDatabase.loggedOutAsync()
    } catch {
      log.error(
        "Logout stopped because local database cleanup failed profile=\(ProjectConfig.userProfile ?? "default") reason=\(error.localizedDescription)",
        error: error
      )
      LoggingOutWindowController.dismiss()
      presentLogoutCleanupFailureAlert()
      return
    }

    dependencies.appUndo.clear()
    await Auth.shared.logOut()

    SettingsWindowController.closeIfOpen()
    dependencies.navigation.reset()
    dependencies.nav.reset()
    dependencies.viewModel.navigate(.onboarding)
    MainWindowOpenCoordinator.shared.openOnboarding()
  }

  private func notifyServerLogout() async {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await InlineRPCClient.shared.logout()
        }
        group.addTask {
          try await Task.sleep(for: .seconds(2))
          throw LogoutNotificationTimeoutError()
        }

        _ = try await group.next()
        group.cancelAll()
      }
    } catch {
      log.warning(
        "Server logout notification did not complete; continuing local logout reason=\(type(of: error))"
      )
    }
  }

  private func presentLogoutCleanupFailureAlert() {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Inline couldn’t finish logging out"
    alert.informativeText =
      "Your local data could not be cleared, so Inline kept this logout pending. Quit and reopen Inline to try again safely."
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

private struct LogoutNotificationTimeoutError: Error {}

// MARK: - URL Scheme Handling

extension AppDelegate {
  @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
    guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
          let url = URL(string: urlString)
    else {
      log.error("Failed to parse URL from event")
      return
    }

    if Self.isCLIAuthURL(url) {
      log.debug("Received local CLI auth request")
    } else if url.host?.lowercased() == "join" {
      log.debug("Received space join URL")
    } else {
      log.debug("Received URL: \(url)")
    }
    handleCustomURL(url)
  }
}
