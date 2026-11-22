import Auth
import Combine
import InlineCompatUI
import InlineGrid
import InlineIOSFoundation
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import Translation
import UIKit

/// The signed-in app: tabs bound to the router, home toolbar, sheets and home bootstrap.
/// Replaces `ExperimentalAuthedRootView`.
///
/// Tabs use the newest UIKit API each system has: `UITab`/`UISearchTab` (iOS 18/26) with
/// New Thread as an action tab on 26 that becomes prominent on 27; classic tab bar items before.
@MainActor
final class MainShellController: UITabBarController, UITabBarControllerDelegate {
  let router: Router
  let appDelegate: AppDelegate
  let mainViewRouter: MainViewRouter
  let home: HomeShellState
  let data: DataManager
  let spaces: CompactSpaceList
  let homeList: ExperimentalHomeListStore
  let homeActions = ExperimentalHomeActionCoordinator()
  let bridgeSupport = BridgeSupport()
  let sheetDismissalRelay = SheetDismissalRelay()
  private let translation = ExperimentalHomeTranslationCoordinator()

  private var stacks: [AppTab: RouterNavigationController] = [:]
  /// `UITab` per app tab on iOS 18+ (stored untyped for the iOS 15 build).
  private var tabObjects: [AppTab: AnyObject] = [:]
  private var homeRoots: [HomeListViewController] = []
  private var cancellables: Set<AnyCancellable> = []
  private weak var presentedSheetController: UIViewController?
  private var presentedSheetValue: Sheet?
  private var bootstrapTask: Task<Void, Never>?
  private var bootstrapRetryAttempt = 0
  private var isApplyingSelection = false

  private static let newThreadTabID = "newThread"

  init(router: Router, appDelegate: AppDelegate, mainViewRouter: MainViewRouter, restoredHomeState: [String: String]) {
    self.router = router
    self.appDelegate = appDelegate
    self.mainViewRouter = mainViewRouter
    let database = AppDatabase.shared
    home = HomeShellState(sceneState: restoredHomeState)
    data = DataManager(database: database)
    spaces = CompactSpaceList(db: database)
    homeList = ExperimentalHomeListStore(database: database, initialConfiguration: home.listConfiguration)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func sceneState() -> [String: String] { home.sceneState }

  // MARK: Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    normalizeRestoredTabs()
    buildTabs()
    bindRouter()
    bindHomeState()
    bindHomeList()
    bindSpaces()
    startBootstrap()
    observeLocalDataCleared()
    scheduleWhatsNew()
  }

  // MARK: Tabs

  private func normalizeRestoredTabs() {
    // Legacy tabs (.chats/.spaces/.archived) fold into All Chats.
    switch router.selectedTab {
    case .allChats, .inbox, .search: break
    default: router.selectedTab = .allChats
    }
  }

  private func makeStack(for tab: AppTab, root: UIViewController) -> RouterNavigationController {
    let stack = RouterNavigationController(tab: tab, router: router, root: root) { [weak self] destination in
      self?.makeController(for: destination) ?? UIViewController()
    }
    stacks[tab] = stack
    return stack
  }

  private func buildTabs() {
    let allRoot = HomeListViewController(shell: self, surface: .allChats)
    let inboxRoot = HomeListViewController(shell: self, surface: .inbox)
    homeRoots = [allRoot, inboxRoot]
    let searchRoot = HomeSearchViewController(shell: self)

    let allStack = makeStack(for: .allChats, root: allRoot)
    let inboxStack = makeStack(for: .inbox, root: inboxRoot)
    let searchStack = makeStack(for: .search, root: searchRoot)

    let allTitle = String(localized: "All Chats")
    let openTitle = String(localized: "Open")
    let searchTitle = String(localized: "Search")

    if #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) {
      let all = UITab(title: allTitle, image: UIImage(systemName: "bubble.left.and.bubble.right"), identifier: AppTab.allChats.rawValue) { _ in allStack }
      let open = UITab(title: openTitle, image: UIImage(systemName: "tray"), identifier: AppTab.inbox.rawValue) { _ in inboxStack }
      let search: UITab
      if #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) {
        search = UISearchTab { _ in searchStack }
        search.title = searchTitle
      } else {
        search = UITab(title: searchTitle, image: UIImage(systemName: "magnifyingglass"), identifier: AppTab.search.rawValue) { _ in searchStack }
      }
      tabObjects = [.allChats: all, .inbox: open, .search: search]
      var tabs: [UITab] = [all, open, search]
      if #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) {
        // An action, not a page: selection is vetoed in `shouldSelectTab`.
        let newThread = UITab(
          title: String(localized: "New Thread"),
          image: UIImage(systemName: "square.and.pencil"),
          identifier: Self.newThreadTabID
        ) { _ in UIViewController() }
        tabs.append(newThread)
      }
      self.tabs = tabs
      if #available(iOS 27.0, *), CompatRuntime.allows(.iOS27) {
        prominentTabIdentifier = Self.newThreadTabID
      }
    } else {
      allStack.tabBarItem = UITabBarItem(title: allTitle, image: UIImage(systemName: "bubble.left.and.bubble.right"), tag: 0)
      inboxStack.tabBarItem = UITabBarItem(title: openTitle, image: UIImage(systemName: "tray"), tag: 1)
      searchStack.tabBarItem = UITabBarItem(tabBarSystemItem: .search, tag: 2)
      viewControllers = [allStack, inboxStack, searchStack]
    }
    selectTab(router.selectedTab)
  }

  private func selectTab(_ tab: AppTab) {
    isApplyingSelection = true
    defer { isApplyingSelection = false }
    if #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) {
      if let target = tabObjects[tab] as? UITab, selectedTab !== target {
        selectedTab = target
      }
    } else if let stack = stacks[tab] {
      selectedViewController = stack
    }
  }

  private func appTab(for controller: UIViewController?) -> AppTab? {
    stacks.first(where: { $0.value === controller })?.key
  }

  @available(iOS 18.0, *)
  func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
    if tab.identifier == Self.newThreadTabID {
      startNewThread()
      return false
    }
    return true
  }

  @available(iOS 18.0, *)
  func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
    guard !isApplyingSelection,
          let tab = tabObjects.first(where: { $0.value === selectedTab })?.key
    else { return }
    if router.selectedTab != tab {
      router.selectedTab = tab
    }
  }

  func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
    guard !isApplyingSelection, let tab = appTab(for: viewController) else { return }
    if router.selectedTab != tab {
      router.selectedTab = tab
    }
  }

  // MARK: Router

  private func bindRouter() {
    observe { [weak self] in
      guard let self else { return }
      let tab = router.selectedTab
      if appTab(for: selectedViewController) != tab {
        selectTab(tab)
      }
    }
    observe { [weak self] in
      guard let self else { return }
      let sheet = router.presentedSheet
      syncSheet(sheet)
    }
  }

  private func syncSheet(_ sheet: Sheet?) {
    if let sheet {
      guard sheet != presentedSheetValue else { return }
      presentedSheetController?.dismiss(animated: false)
      presentedSheetValue = sheet
      let controller = makeSheetController(for: sheet)
      presentedSheetController = controller
      topmostPresented.present(controller, animated: true)
    } else if let controller = presentedSheetController {
      presentedSheetValue = nil
      presentedSheetController = nil
      if controller.presentingViewController != nil {
        controller.dismiss(animated: true)
      }
    }
  }

  /// Called by sheet containers when the person dismisses them.
  func sheetDidDismiss(_ controller: UIViewController) {
    guard controller === presentedSheetController else { return }
    presentedSheetController = nil
    presentedSheetValue = nil
    if router.presentedSheet != nil {
      router.dismissSheet()
    }
  }

  // MARK: Home state

  private func bindHomeState() {
    observe { [weak self] in
      guard let self else { return }
      let configuration = home.listConfiguration
      homeList.setConfiguration(configuration)
      refreshHomeToolbars()
    }
  }

  private func bindHomeList() {
    homeList.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self else { return }
        updateInboxBadge(state.presentation.inboxUnreadCount, isEmpty: state.presentation.inbox.isEmpty)
        translation.process(presentation: state.presentation, currentPeers: currentChatPeers)
      }
      .store(in: &cancellables)

    TranslationState.shared.subject
      .receive(on: DispatchQueue.main)
      .sink { [weak self] event in
        guard let self else { return }
        translation.translationStateChanged(
          peer: event.0,
          isEnabled: event.1,
          presentation: homeList.state.presentation,
          currentPeers: currentChatPeers
        )
      }
      .store(in: &cancellables)

    Api.realtime.stateObject.$displayedConnectionState
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.refreshHomeToolbars() }
      .store(in: &cancellables)

    INUserSettings.current.notification.$mode
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.refreshHomeToolbars() }
      .store(in: &cancellables)
  }

  private var currentChatPeers: Set<Peer> {
    Set(router.selectedTabPath.compactMap(\.chatPeer))
  }

  private func updateInboxBadge(_ count: Int, isEmpty: Bool) {
    let badge = count > 0 ? (count > 99 ? "99+" : "\(count)") : nil
    let image = UIImage(systemName: isEmpty ? "tray" : "tray.full.fill")
    if #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) {
      if let tab = tabObjects[.inbox] as? UITab {
        tab.badgeValue = badge
        tab.image = image
      }
    } else if let item = stacks[.inbox]?.tabBarItem {
      item.badgeValue = badge
      item.image = image
    }
  }

  private func bindSpaces() {
    spaces.$spaces
      .receive(on: DispatchQueue.main)
      .sink { [weak self] spaces in
        guard let self else { return }
        if let active = home.activeSpaceId, !spaces.isEmpty, !spaces.contains(where: { $0.id == active }) {
          home.activeSpaceId = nil
        }
        refreshHomeToolbars()
      }
      .store(in: &cancellables)
  }

  var activeSpace: Space? {
    guard let id = home.activeSpaceId else { return nil }
    return spaces.spaces.first(where: { $0.id == id })
  }

  func selectSpace(_ spaceID: Int64?) {
    home.activeSpaceId = spaceID
    router.popToRoot(for: router.selectedTab)
  }

  // MARK: Toolbar

  func refreshHomeToolbars() {
    homeRoots.forEach { $0.updateToolbar() }
  }

  // MARK: Actions

  /// Push a destination in the current tab (home rows, menus).
  func open(_ destination: Destination) {
    router.push(destination, for: router.selectedTab)
  }

  func startNewThread() {
    let spaceID = home.activeSpaceId
    if #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) {
      presentNewThreadComposer(spaceID: spaceID)
    } else {
      createThreadInstantly(spaceID: spaceID)
    }
  }

  /// iOS 26+: the thread starts from its first message (and takes its title from it), in the
  /// existing composer sheet. Bridged until its UIKit port lands.
  private func presentNewThreadComposer(spaceID: Int64?) {
    guard #available(iOS 26.0, *) else {
      createThreadInstantly(spaceID: spaceID)
      return
    }
    let sheet = SwiftUIBridge.sheet(
      NewThreadComposerSheet(initialSpaceID: spaceID) { [weak self] peer in
        self?.open(.chat(peer: peer))
      },
      shell: self
    )
    topmostPresented.present(sheet, animated: true)
  }

  private func createThreadInstantly(spaceID: Int64?) {
    guard !home.isCreatingThread else { return }
    guard let currentUserId = Auth.shared.currentUserId else {
      ToastManager.shared.showToast(
        "You're signed out. Please log in again.", type: .error, systemImage: "exclamationmark.triangle"
      )
      return
    }
    home.isCreatingThread = true
    Task { [weak self] in
      do {
        let realtime = Api.realtime
        let chatId = try await realtime.createThreadLocally(
          title: "", emoji: nil, isPublic: false, spaceId: spaceID, participants: [currentUserId]
        )
        let peer: Peer = .thread(id: chatId)
        await realtime.sendQueued(.updateDialogOpen(peerId: peer, open: true, requiresChatCreated: true))
        self?.home.isCreatingThread = false
        self?.open(.chat(peer: peer))
      } catch {
        self?.home.isCreatingThread = false
        ToastManager.shared.showToast("Failed to create thread.", type: .error, systemImage: "exclamationmark.triangle")
        Log.shared.error("Failed to create thread", error: error)
      }
    }
  }

  // MARK: Bootstrap

  private func startBootstrap() {
    bootstrapTask?.cancel()
    bootstrapTask = Task { [weak self] in
      guard let self else { return }
      appDelegate.notificationHandler.setAuthenticated(value: true)
      do {
        let spaces = try await InviteDirectory.spaces(database: spaces.db)
        guard !Task.isCancelled else { return }
        if let active = home.activeSpaceId, !spaces.contains(where: { $0.id == active }) {
          home.activeSpaceId = nil
        }
        bootstrapRetryAttempt = 0
      } catch {
        guard !Task.isCancelled else { return }
        Log.shared.error("Home bootstrap failed", error: error)
        bootstrapRetryAttempt += 1
        let delay = min(30.0, pow(2.0, Double(bootstrapRetryAttempt)))
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        startBootstrap()
      }
    }
  }

  private func observeLocalDataCleared() {
    NotificationCenter.default.publisher(for: .localDataCleared)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.homeList.refresh()
        self?.startBootstrap()
      }
      .store(in: &cancellables)
  }

  private func scheduleWhatsNew() {
    guard WhatsNewStore.shared.pending != nil else { return }
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled, WhatsNewStore.shared.pending != nil,
            router.presentedSheet == nil, router.selectedTabPath.isEmpty
      else { return }
      router.presentSheet(.whatsNew)
    }
  }

  deinit {
    bootstrapTask?.cancel()
  }
}
