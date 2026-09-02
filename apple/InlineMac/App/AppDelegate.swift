import AppKit
import Auth
import Combine
import Darwin
import InlineConfig
import InlineKit
import InlineMacScripting
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
  @MainActor private lazy var scriptingAdapter = MacScriptingAdapter(delegate: self)
  @MainActor private var accountOperationAdmissionIsOpen: Bool {
    !isLoggingOut && !isResettingLocalData && terminationTask == nil
  }
  @MainActor var scriptingAccountIsReady: Bool {
    accountOperationAdmissionIsOpen
      && dependencies.viewModel.topLevelRoute == .main
  }
  @MainActor private var terminationTask: Task<Void, Never>?
  @MainActor var isLoggingOut = false
  @MainActor private var isResettingLocalData = false
  @MainActor private var pendingLogoutAfterLocalDataReset: Bool?
  @MainActor var logoutAttempt: MacLogoutAttempt?
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
  private var notificationNavigationTask: Task<Void, Never>?

  func applicationWillFinishLaunching(_: Notification) {
    InlineMacIntents.register { [weak self] in
      self?.scriptingAccountIsReady == true
    }
    InlineMacShortcuts.updateAppShortcutParameters()
    let launchSpan = PerformanceTrace.begin("ApplicationWillFinish", category: .launch)
    defer { launchSpan.end() }

    NSWindow.allowsAutomaticWindowTabbing = true

    // Freeze the chat font before any message layout or settings UI is created.
    let typographySpan = PerformanceTrace.begin("ChatTypographyBootstrap", category: .launch)
    _ = ChatTypography.current
    typographySpan.end()

    let devtoolsSpan = PerformanceTrace.begin("MacDevtoolsBootstrap", category: .launch)
    MacDevtools.bootstrap()
    devtoolsSpan.end()

    let defaultsSpan = PerformanceTrace.begin("GlobalSettingsBootstrap", category: .launch)
    registerMacGlobalSettings()
    defaultsSpan.end()

    // Setup Notifications Delegate
    let notificationsSpan = PerformanceTrace.begin("NotificationBootstrap", category: .launch)
    setupNotifications()
    notificationsSpan.end()

    let dependenciesSpan = PerformanceTrace.begin("AppDependenciesInit", category: .launch)
    _ = dependencies
    dependenciesSpan.end()
    InlineScripting.install { [weak self] request in
      guard let self else { throw ScriptingError.unavailable }
      return try await self.scriptingAdapter.execute(request)
    }
  }

  func applicationDidFinishLaunching(_: Notification) {
    MessageGestureTrace.restoreSetting()
    let launchSpan = PerformanceTrace.begin("ApplicationDidFinish", category: .launch)
    defer { launchSpan.end() }

    let servicesSpan = PerformanceTrace.begin("LaunchServicesInit", category: .launch)
    initializeServices()
    servicesSpan.end()

    let appearanceSpan = PerformanceTrace.begin("AppearanceBootstrap", category: .launch)
    setupAppearanceSetting()
    setupThemeSetting()
    appearanceSpan.end()

    let menuSpan = PerformanceTrace.begin("MainMenuBootstrap", category: .launch)
    setupMainMenu()
    menuSpan.end()
    Task { @MainActor in
      await dependencies.cliInstaller.refresh()
    }
    presentInstallLocationPromptIfNeeded()
    registerMainWindowCoordinator()
    setupRealtimeConnectionFailureObserver()
    setupRealtimeAuthInvalidatedObserver()
    setupAuthAccountRecoveryObserver()
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
      let messagesPublisher = MessagesPublisher.shared
      messagesPublisher.closeAdmissionForTermination()
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
        async let publisherTermination: Void = messagesPublisher.waitForAdmittedDatabaseReadsForTermination()
        async let realtimeTermination: Void = realtime.prepareForTermination()
        async let reservationTermination: Void = ReservedChatIDPool.shared.prepareForTermination()
        _ = await (publisherTermination, realtimeTermination, reservationTermination)

        do {
          try await database.waitForPendingOperationsForTermination()
        } catch {
          log.error("Database did not drain cleanly during application termination", error: error)
          return
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
    guard accountOperationAdmissionIsOpen else { return }
    let isInitialActivation = didHandleInitialActivation == false
    let activationSpan = PerformanceTrace.begin(
      "ApplicationDidBecomeActive",
      category: .launch,
      "initial=\(isInitialActivation ? 1 : 0)"
    )
    defer { activationSpan.end() }

//    Task {
//      if Auth.shared.isLoggedIn {
//        // Mark online
//        try? await DataManager.shared.updateStatus(online: true)
//      }
//    }
    Task { @MainActor [weak self] in
      guard let self, self.accountOperationAdmissionIsOpen, Auth.shared.isLoggedIn else { return }
      await self.dependencies.gridRuntime.applicationDidWake()
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
      AppSettings.showGridInSidebarKey: true,
      AppSettings.messageDoubleClickActionKey: MessageGestureAction.defaultDoubleClick.rawValue,
      AppSettings.messageHoldActionKey: MessageGestureAction.defaultHold.rawValue,
    ])
  }

  @discardableResult
  @MainActor private func setupMainWindow() -> MainWindowController {
    let span = PerformanceTrace.begin("SetupMainWindow", category: .launch)
    defer { span.end() }
    return MainWindowController.showDefault(dependencies: dependencies)
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

  @MainActor func cancelPendingSpaceJoin() {
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
    guard !isLoggingOut, !isResettingLocalData,
          Auth.shared.getHasPendingAccountTransition() == false,
          Auth.shared.getStatus().isAuthenticated
    else { throw AuthStorageError.logoutInProgress }
    isResettingLocalData = true
    defer {
      isResettingLocalData = false
      if let notifyServer = pendingLogoutAfterLocalDataReset {
        pendingLogoutAfterLocalDataReset = nil
        Task { @MainActor [weak self] in
          await self?.performLogOut(notifyServer: notifyServer)
        }
      }
    }
    Auth.shared.invalidateLoginAttemptsSynchronously()
    let restoreRoute = TopLevelRoute.initial(for: Auth.shared.getStatus())

    await dependencies.session.resetAndWait()
    try requireLocalDataResetMayContinue()
    dependencies.viewModel.navigate(.loading)
    MainWindowController.resetAllNavigation()

    await Task.yield()

    do {
      await ReservedChatIDPool.shared.pauseAndDrain()
      await Api.realtime.loggedOut()
      try requireLocalDataResetMayContinue()
      await dependencies.realtime.loggedOut()
      try requireLocalDataResetMayContinue()
      await FileUploader.shared.cancelAll()
      await FileCache.shared.cancelAllDownloads()
      await FileDownloader.shared.resetSession()
      NotionTaskService.shared.resetSession()
      await Drafts2.shared.resetForAccountChange()
      await QuickSearchUsageStore.shared.clearCurrentAccount()
      await Transactions.shared.clearAllAndWait()
      try requireLocalDataResetMayContinue()
      ObjectCache.shared.clear()
      try await FileCache.shared.clearCache()
      await dependencies.commandBarCatalog.reset()
      try AppDatabase.clearDB()
    } catch {
      guard terminationTask == nil, Auth.shared.getHasPendingAccountTransition() == false, !isLoggingOut else {
        dependencies.viewModel.navigate(.loading)
        throw AuthStorageError.logoutInProgress
      }
      await Api.realtime.resumeAfterLocalDataReset()
      await ReservedChatIDPool.shared.resume(realtimeV2: Api.realtime)
      await dependencies.realtime.start()
      dependencies.viewModel.navigate(restoreRoute)
      throw error
    }

    try requireLocalDataResetMayContinue()
    await Api.realtime.resumeAfterLocalDataReset()
    await ReservedChatIDPool.shared.resume(realtimeV2: Api.realtime)
    try requireLocalDataResetMayContinue()
    await dependencies.realtime.start()
    try requireLocalDataResetMayContinue()
    dependencies.appUndo.clear()

    dependencies.navigation.reset()
    dependencies.nav.reset()

    MainWindowController.closeAll()
    MainWindowOpenCoordinator.shared.resetWindows()

    dependencies.viewModel.navigate(restoreRoute)
    setupMainWindow()
  }

  @MainActor
  private func requireLocalDataResetMayContinue() throws {
    guard terminationTask == nil, !isLoggingOut, Auth.shared.getHasPendingAccountTransition() == false,
          Auth.shared.getStatus().isAuthenticated
    else { throw AuthStorageError.logoutInProgress }
  }

  /// Serializes the two destructive account teardown owners. A logout requested during local-data
  /// reset starts immediately after that reset returns (successfully or otherwise), never midway
  /// through its realtime/database phases.
  @MainActor
  func deferLogoutUntilLocalDataResetFinishes(notifyServer: Bool) -> Bool {
    guard isResettingLocalData else { return false }
    pendingLogoutAfterLocalDataReset = (pendingLogoutAfterLocalDataReset ?? false) || notifyServer
    return true
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

  private func setupAuthAccountRecoveryObserver() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAuthAccountRecoveryRequiredNotification),
      name: .authAccountRecoveryRequired,
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

  @objc private func handleAuthAccountRecoveryRequiredNotification() {
    Task { [weak self] in
      await self?.performLogOut(notifyServer: false)
    }
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

  @MainActor func handleNotification(_ response: UNNotificationResponse) {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
#if DEBUG || DEBUG_BUILD
    // Playground notifications exercise system rendering without fixture navigation.
    if let userInfo = response.notification.request.content.userInfo as? [String: Any],
       userInfo["playgroundNotification"] as? Bool == true
    {
      return
    }
#endif
    // Reserve tap order before any chat lookup, including encrypted fallbacks.
    notificationNavigationTask?.cancel()
    notificationNavigationTask = nil
    log.debug("Opening notification target")

    guard let userInfo = response.notification.request.content.userInfo as? [String: Any] else {
      return
    }

    let threadIdentifier = response.notification.request.content.threadIdentifier

    if handleGridScreenShareNotification(userInfo) {
      return
    } else if let target = MessageNotificationTarget(userInfo: userInfo, threadIdentifier: threadIdentifier) {
      guard let account = MessageNotificationAccount.capture(userInfo: userInfo) else { return }
      notificationNavigationTask = Task(priority: .userInitiated) { @MainActor in
        let peerId = await target.resolvePeer(fetchIfMissingFor: account)
        guard !Task.isCancelled else { return }
        guard let peerId, MessageNotificationAccount.isCurrent(account) else {
          log.warning("Failed to resolve notification conversation")
          return
        }
        self.openChat(peer: peerId, targetMessageId: target.messageID)
        guard !Task.isCancelled, MessageNotificationAccount.isCurrent(account) else { return }
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

  private func coerceInt64(_ value: Any?) -> Int64? {
    if let int64 = value as? Int64 { return int64 }
    if let int = value as? Int { return Int64(int) }
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
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
