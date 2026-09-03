import Auth
import InlineKit
import InlineUI
import Logger
import QuartzCore
import RealtimeV2
import SwiftUI
import Translation
import UIKit

private enum RootTab: String, Hashable {
  case inbox
  case allChats
  case search
  case newChat

  init(appTab: AppTab) {
    switch appTab {
    case .allChats, .archived:
      self = .allChats
    case .search:
      self = .search
    case .inbox, .chats, .spaces:
      self = .inbox
    }
  }

  var appTab: AppTab {
    switch self {
    case .inbox:
      .inbox
    case .allChats:
      .allChats
    case .search:
      .search
    case .newChat:
      // Selection is intercepted before this compatibility value is used.
      .allChats
    }
  }
}

private struct PendingSearchExit {
  let destinationTab: RootTab
  let destination: Destination?
  let createsThread: Bool
}

private enum HomeBootstrapOutcome: Sendable {
  case success
  case failure
  case cancelled
}

struct ExperimentalRootView: View {
  @StateObject private var onboardingNavigation = OnboardingNavigation()
  @StateObject private var api = ApiClient()
  @StateObject private var userData = UserData()
  @StateObject private var mainViewRouter = MainViewRouter()
  @StateObject private var fileUploadViewModel = FileUploadViewModel()
  @StateObject private var tabsManager = TabsManager()

  @Environment(Router.self) private var router
  @EnvironmentObject private var navigation: Navigation

  var body: some View {
    Group {
      switch mainViewRouter.route {
      case .main:
        // Keep auth-session state under the authed subtree so a fresh login rebuilds bootstrap state.
        ExperimentalAuthedRootView()
      case .onboarding:
        OnboardingView()
      case .loading:
        IOSStartupLoadingView(router: mainViewRouter)
      }
    }
    .environment(router)
    .environmentObject(onboardingNavigation)
    .environmentObject(Api.realtime.stateObject)
    .environmentObject(api)
    .environmentObject(userData)
    .environmentObject(mainViewRouter)
    .environmentObject(fileUploadViewModel)
    .environmentObject(tabsManager)
    .onReceive(NotificationCenter.default.publisher(for: .realtimeV2AuthInvalidated)) { _ in
      Task {
        await LogoutPerformer.perform(
          notifyServer: false,
          mainRouter: mainViewRouter,
          navigation: navigation,
          onboardingNavigation: onboardingNavigation,
          router: router
        )
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .authAccountRecoveryRequired)) { _ in
      Task {
        await LogoutPerformer.perform(
          notifyServer: false,
          mainRouter: mainViewRouter,
          navigation: navigation,
          onboardingNavigation: onboardingNavigation,
          router: router
        )
      }
    }
    .task {
      guard await Auth.shared.hasPendingLogout() else { return }
      await LogoutPerformer.perform(
        notifyServer: false,
        mainRouter: mainViewRouter,
        navigation: navigation,
        onboardingNavigation: onboardingNavigation,
        router: router
      )
    }
    .toastView()
  }

}

private struct ExperimentalAuthedRootView: View {
  @State private var nav = ExperimentalNavigationModel()
  @State private var homeActions = ExperimentalHomeActionCoordinator()
  @State private var translationCoordinator = ExperimentalHomeTranslationCoordinator()
  @State private var searchQuery = ""
  @State private var searchFocusRequested = false
  @State private var searchInteractionRevision = 0
  @State private var isSearchFieldFocused = false
  @State private var isSearchKeyboardVisible = false
  @State private var lastContentRootTab: RootTab = .allChats
  @State private var pendingSearchExit: PendingSearchExit?
  @State private var isCreatingThread = false
  @State private var isCleaningOpenChats = false
  @State private var isNotificationSettingsPresented = false
  @State private var iPadCommandRequest: IPadCommandRequest?
  @State private var homeBootstrapTask: Task<HomeBootstrapOutcome, Never>?
  @State private var homeBootstrapRetryTask: Task<Void, Never>?
  @State private var homeBootstrapGeneration: UInt64 = 0
  @State private var homeBootstrapRetryAttempt = 0
  @State private var didRestoreSceneHomeState = false
  @SceneStorage("ios.home.activeSpaceID.v1")
  private var sceneActiveSpaceIDRaw = ""
  @SceneStorage("ios.home.allChatsFilter.v1")
  private var allChatsFilterRaw = ChatListFilter.all.rawValue
  @SceneStorage("ios.ipad.sidebarScope.v1")
  private var iPadSidebarScopeRaw = IPadSidebarScope.allChats.rawValue
  @AppStorage("ios.experimental.root.didMigrateExplicitTabs")
  private var didMigrateExplicitTabs = false
  @AppStorage("ios.home.didMigrateActiveSpaceToScene.v1")
  private var didMigrateActiveSpaceToScene = false
  @AppStorage(ExperimentalHomePreferenceKeys.chatScope)
  private var homeChatScopeRaw = ExperimentalHomeChatScope.all.rawValue
  @AppStorage(ExperimentalHomePreferenceKeys.chatItemRenderMode)
  private var chatItemRenderModeRaw = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue
  @AppStorage(ExperimentalHomePreferenceKeys.sortMode)
  private var sortModeRaw = ExperimentalHomeSortMode.recentActivity.rawValue
  @AppStorage private var excludedHomeSpaceIDsRaw: String

  @Environment(Router.self) private var router
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.auth) private var auth
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentStateObject private var data: DataManager
  @EnvironmentStateObject private var compactSpaceList: CompactSpaceList
  @EnvironmentStateObject private var homeListStore: ExperimentalHomeListStore
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager
  @EnvironmentObject private var notificationHandler: NotificationHandler
  @EnvironmentObject private var realtimeState: RealtimeState

  init() {
    let defaults = UserDefaults.standard
    let homeScope = ExperimentalHomeChatScope(
      rawValue: defaults.string(forKey: ExperimentalHomePreferenceKeys.chatScope) ?? ""
    ) ?? .all
    let sortMode = ExperimentalHomeSortMode(
      rawValue: defaults.string(forKey: ExperimentalHomePreferenceKeys.sortMode) ?? ""
    ) ?? .recentActivity
    let userID = Auth.shared.getCurrentUserId()
    let exclusionsKey = ExperimentalHomePreferenceKeys.excludedHomeSpaceIDs(userID: userID)
    let homeSpaceExclusions = HomeSpaceExclusions(
      rawValue: defaults.string(forKey: exclusionsKey) ?? ""
    )
    _excludedHomeSpaceIDsRaw = AppStorage(wrappedValue: "", exclusionsKey)
    let initialHomeConfiguration = ExperimentalHomeListConfiguration(
      spaceID: nil,
      includeSpaceChatsInHome: homeScope == .all,
      homeSpaceExclusions: homeSpaceExclusions,
      inboxSort: sortMode.chatListSort,
      allChatsFilter: .all
    )

    _data = EnvironmentStateObject { env in
      DataManager(database: env.appDatabase)
    }

    _compactSpaceList = EnvironmentStateObject { env in
      CompactSpaceList(db: env.appDatabase)
    }
    _homeListStore = EnvironmentStateObject { env in
      ExperimentalHomeListStore(
        database: env.appDatabase,
        initialConfiguration: initialHomeConfiguration
      )
    }
  }

  var body: some View {
    rootNavigation
      // Phone destinations replace the root tabs; the iPad lane has no tab bar.
      // Neither container needs legacy per-destination tab-bar hiding.
      .environment(\.inlineHideTabBar, false)
      .environmentObject(data)
      .environmentObject(compactSpaceList)
      .environmentObject(homeListStore)
      .environment(homeActions)
      .onReceive(NotificationCenter.default.publisher(for: .localDataCleared)) { _ in
        let previousBootstrap = invalidateHomeBootstrap(resetProgress: true)
        nav.resetHomeDataState()
        homeListStore.refresh()
        Task {
          await refetchCoreDataAfterLocalDataCleared(after: previousBootstrap)
        }
      }
      .task {
        restoreSceneHomeStateIfNeeded()
        await loadHomeDataOnAppear()
      }
      .onChange(of: compactSpaceList.spaces) { _, _ in
        nav.pruneDialogFetchState(validSpaceIds: Set(compactSpaceList.spaces.map(\.id)))
        ensureActiveSpaceExists()
      }
      .onChange(of: homeListStore.state.revision) { _, _ in
        translationCoordinator.process(
          presentation: homeListStore.state.presentation,
          currentPeers: currentChatPeers
        )
      }
      .onReceive(TranslationState.shared.subject) { event in
        let (peer, isEnabled) = event
        translationCoordinator.translationStateChanged(
          peer: peer,
          isEnabled: isEnabled,
          presentation: homeListStore.state.presentation,
          currentPeers: currentChatPeers
        )
      }
      .onDisappear {
        translationCoordinator.cancel()
      }
  }

  private var rootNavigation: some View {
    @Bindable var bindableRouter = router

    return Group {
      if #available(iOS 26.0, *), usesIPadSplitView {
        iPadNavigation
      } else {
        phoneNavigation
      }
    }
    // Prevent child views (e.g. ChatView) from leaking their toolbar appearance
    // back to Root when the shared stack pops.
    .toolbarColorScheme(colorScheme, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .sheet(item: $bindableRouter.presentedSheet) { sheet in
      switch sheet {
      case .chatInfo:
        ExperimentalSheetView(sheet: sheet, onSelectSpace: selectSpaceInHome)
          .presentationDetents([.medium, .large])
      case .createSpace:
        ExperimentalSheetView(sheet: sheet, onSelectSpace: selectSpaceInHome)
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
          .presentationContentInteraction(.scrolls)
      default:
        ExperimentalSheetView(sheet: sheet, onSelectSpace: selectSpaceInHome)
      }
    }
    .onAppear {
      restoreSceneHomeStateIfNeeded()
      migrateLegacySpaceDestinationIfNeeded()
      migrateLegacyRootTabsIfNeeded()
      let routedTab = RootTab(appTab: bindableRouter.selectedTab)
      let desiredRootTab = switch routedTab {
      case .newChat:
        RootTab.allChats
      case .allChats, .inbox, .search:
        routedTab
      }
      let desiredTab = desiredRootTab.appTab
      configureHomeList()
      if bindableRouter.selectedTab != desiredTab {
        bindableRouter.selectedTab = desiredTab
      }
      if desiredRootTab == .search {
        searchFocusRequested = false
      } else {
        lastContentRootTab = desiredRootTab
      }
      if chatItemRenderModeRaw == ExperimentalHomeChatItemRenderMode.oneLineLastMessage.rawValue {
        chatItemRenderModeRaw = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue
      }
      if usesIPadSplitView { router.tracksHistory = true }
    }
    .onChange(of: bindableRouter.selectedTab) { oldValue, newValue in
      if usesIPadSplitView, newValue != IPadNavigationLane.canonicalTab {
        IPadNavigationLane.normalizeRestoredState(in: router)
        return
      }
      let previousRootTab = RootTab(appTab: oldValue)
      let desiredRootTab = RootTab(appTab: newValue)
      if previousRootTab == .search, desiredRootTab != .search {
        // External navigation owns its route immediately. Invalidate any pending
        // Search-result callback and resign; IOS-06 owns route-level deferral.
        searchInteractionRevision &+= 1
        pendingSearchExit = nil
        searchFocusRequested = false
      }
      let desiredTab = desiredRootTab.appTab
      if bindableRouter.selectedTab != desiredTab {
        bindableRouter.selectedTab = desiredTab
        return
      }
      if desiredRootTab == .search {
        if previousRootTab != .search, previousRootTab != .newChat {
          lastContentRootTab = previousRootTab
        }
        pendingSearchExit = nil
        searchFocusRequested = false
      } else if desiredRootTab != .newChat {
        lastContentRootTab = desiredRootTab
      }
      guard previousRootTab != desiredRootTab else { return }
      ExperimentalHomeNavigationPerformance.measureTabSwitch(
        from: previousRootTab.rawValue,
        to: desiredRootTab.rawValue,
        rows: homeListStore.state.presentation.allChatCount
      )
    }
    .onChange(of: bindableRouter.selectedTabPath) { oldPath, newPath in
      guard let previousPeer = oldPath.last?.chatPeer,
            newPath.contains(where: { $0.chatPeer == previousPeer }) == false
      else { return }
      ExperimentalHomeNavigationPerformance.measureBackToHome(
        rows: homeListStore.state.presentation.allChatCount
      )
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
      guard isSearchRootSelected else { return }
      withAnimation(searchChromeAnimation) {
        isSearchKeyboardVisible = true
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
      withAnimation(searchChromeAnimation) {
        isSearchKeyboardVisible = false
        completePendingSearchExit()
      }
    }
    .onChange(of: nav.activeSpaceId) { _, _ in
      sceneActiveSpaceIDRaw = nav.activeSpaceId.map(String.init) ?? ""
      configureHomeList()
    }
    .onChange(of: sortModeRaw) { _, _ in
      configureHomeList()
    }
    .onChange(of: homeChatScopeRaw) { _, _ in
      configureHomeList()
    }
    .onChange(of: allChatsFilterRaw) { _, _ in
      configureHomeList()
    }
    .onChange(of: excludedHomeSpaceIDsRaw) { _, _ in
      configureHomeList()
    }
  }

  @available(iOS 26.0, *)
  private var iPadNavigation: some View {
    @Bindable var bindableRouter = router
    @Bindable var bindableNav = nav

    return IPadRootView(
      path: $bindableRouter[IPadNavigationLane.canonicalTab],
      router: router,
      tab: IPadNavigationLane.canonicalTab,
      nav: bindableNav,
      onSelectSpace: selectSpaceInHome,
      onMigrateLegacySpaceDestination: migrateLegacySpaceDestination
    ) { selection in
      iPadSidebar(selection: selection)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: Notification.Name("chatDeletedNotification"))
        .receive(on: DispatchQueue.main)
    ) { notification in
      guard let chatID = notification.userInfo?["chatId"] as? Int64 else { return }
      router.removeChatRoutes(for: .thread(id: chatID))
    }
    .focusedSceneValue(
      \.iPadNavigationContext,
      IPadNavigationContext(router: router)
    )
    .focusedSceneValue(\.iPadSidebarScope, iPadSidebarScopeBinding)
    .focusedSceneValue(\.iPadCommandRequest, $iPadCommandRequest)
    .onChange(of: iPadCommandRequest) { _, request in
      handleIPadCommandRequest(request)
    }
  }

  private func handleIPadCommandRequest(_ request: IPadCommandRequest?) {
    guard let request else { return }
    iPadCommandRequest = nil
    switch request {
    case .newThread:
      let spaceID: Int64? = nav.activeSpaceId
      createThreadInstantly(spaceId: spaceID)
    case .openArchive:
      openHomeDestination(.archived)
    }
  }

  // Keep the device lane stable when an iPad window becomes compact. The
  // native split view owns size-class adaptation; iPhone never enters this lane.
  private var usesIPadSplitView: Bool {
    IPadNavigationLane.isEnabled
  }

  private var iPadSidebarScope: IPadSidebarScope {
    IPadSidebarScope(rawValue: iPadSidebarScopeRaw) ?? .allChats
  }

  private var iPadSidebarScopeBinding: Binding<IPadSidebarScope> {
    Binding(
      get: { iPadSidebarScope },
      set: { iPadSidebarScopeRaw = $0.rawValue }
    )
  }

  @available(iOS 26.0, *)
  private func iPadSidebar(selection: Binding<Destination?>) -> some View {
    ExperimentalHomeView(
      initialTab: iPadSidebarScope.homeTab,
      allChatsFilter: ChatListFilter(rawValue: allChatsFilterRaw) ?? .all,
      selection: selection
    )
    // ExperimentalHomeView selects its pinned disclosure persistence key in init.
    // Give each sidebar projection an explicit identity when the scope changes.
    .id(iPadSidebarScope)
    .background(Color(.systemBackground))
    .experimentalRootTitleDisplayMode()
    .navigationTitle("")
    .toolbar {
      experimentalToolbarContent()
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      IPadSidebarSwitcher(selection: iPadSidebarScopeBinding)
    }
  }

  private var phoneNavigation: some View {
    @Bindable var bindableRouter = router
    @Bindable var bindableNav = nav

    return NavigationStack(path: $bindableRouter[bindableRouter.selectedTab]) {
      rootPage(nav: bindableNav)
        .background(Color(.systemBackground))
        .experimentalRootTitleDisplayMode()
        .navigationTitle("")
        .toolbarVisibility(isSearchActivePresentation ? .hidden : .visible, for: .navigationBar)
        .animation(searchChromeAnimation, value: isSearchActivePresentation)
        .toolbar {
          experimentalToolbarContent()
        }
        .navigationDestination(for: Destination.self) { destination in
          ExperimentalDestinationView(
            nav: bindableNav,
            destination: destination,
            onSelectSpace: selectSpaceInHome,
            onMigrateLegacySpaceDestination: migrateLegacySpaceDestination
          )
        }
    }
  }

  private func migrateLegacyRootTabsIfNeeded() {
    guard !didMigrateExplicitTabs else { return }

    if router[.inbox].isEmpty {
      router[.inbox] = router[.chats]
    }
    if router[.allChats].isEmpty {
      router[.allChats] = router[.archived]
    }

    switch router.selectedTab {
    case .chats, .spaces:
      router.selectedTab = .inbox
    case .archived:
      router.selectedTab = .allChats
    case .inbox, .allChats, .search:
      break
    }
    didMigrateExplicitTabs = true
  }

  private var currentChatPeers: Set<Peer> {
    Set(router.selectedTabPath.compactMap(\.chatPeer))
  }

  private func rootPage(nav: ExperimentalNavigationModel) -> some View {
    @Bindable var bindableNav = nav

    return rootTabs(nav: bindableNav)
      .background(Color(.systemBackground))
  }

  private func rootTabs(nav: ExperimentalNavigationModel) -> some View {
    TabView(selection: rootTabSelection) {
      Tab("All Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .allChats) {
        chatsRoot(rootTab: .allChats)
      }

      // TODO: Decide the badge color before bridging UIKit's global
      // `UITabBarItem.badgeColor`; SwiftUI's native tab badge has no tint API.
      Tab("Open", systemImage: openChatsTabSystemImage, value: .inbox) {
        chatsRoot(rootTab: .inbox)
      }
      .badge(homeListStore.state.presentation.inboxUnreadCount)

      Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
        ExperimentalSearchView(
          query: $searchQuery,
          focusRequested: $searchFocusRequested,
          isActivePresentation: isSearchActivePresentation,
          activeSpaceId: nav.activeSpaceId,
          onFocusChanged: searchFocusChanged,
          onClose: closeSearch,
          onOpenResult: openSearchResult
        )
      }

      if #available(iOS 27.0, *) {
        Tab("New Thread", systemImage: "plus", value: .newChat, role: .prominent) {
          Color.clear
        }
      } else if #available(iOS 26.0, *) {
        // iOS 26 has no `.prominent` role, so New Thread remains a standard
        // native tab action until the role is available.
        Tab("New Thread", systemImage: "plus", value: .newChat) {
          Color.clear
        }
      }
    }
    .background(Color(.systemBackground))
  }

  private var openChatsTabSystemImage: String {
    let presentation = homeListStore.state.presentation
    return presentation.inboxPinned.isEmpty && presentation.inboxUnpinned.isEmpty
      ? "tray"
      : "tray.full.fill"
  }

  private var rootTabSelection: Binding<RootTab> {
    Binding(
      get: { RootTab(appTab: router.selectedTab) },
      set: { newValue in
        if newValue == .newChat {
          if RootTab(appTab: router.selectedTab) == .search {
            requestSearchExit(to: lastContentRootTab, createsThread: true)
          } else {
            createThreadInstantly(spaceId: nav.activeSpaceId)
          }
          return
        }

        let currentRootTab = RootTab(appTab: router.selectedTab)
        if currentRootTab == .search, newValue != .search {
          requestSearchExit(to: newValue)
        } else {
          selectRootTab(newValue, previousRootTab: currentRootTab)
        }
      }
    )
  }

  private var isSearchRootSelected: Bool {
    !usesIPadSplitView && RootTab(appTab: router.selectedTab) == .search && router.selectedTabPath.isEmpty
  }

  private var isSearchActivePresentation: Bool {
    isSearchRootSelected
      && (searchFocusRequested || isSearchFieldFocused || isSearchKeyboardVisible)
  }

  private var searchChromeAnimation: Animation? {
    reduceMotion ? nil : .smooth(duration: 0.24)
  }

  private func selectRootTab(_ newRootTab: RootTab, previousRootTab: RootTab) {
    guard newRootTab != .newChat else { return }

    if newRootTab == .search {
      if previousRootTab != .search, previousRootTab != .newChat {
        lastContentRootTab = previousRootTab
      }
      pendingSearchExit = nil
      searchFocusRequested = false
    } else {
      lastContentRootTab = newRootTab
    }

    if router.selectedTab != newRootTab.appTab {
      router.selectedTab = newRootTab.appTab
    }
  }

  private func requestSearchExit(
    to destinationTab: RootTab,
    destination: Destination? = nil,
    createsThread: Bool = false
  ) {
    searchInteractionRevision &+= 1
    let requiresFocusSettlement = searchFocusRequested || isSearchFieldFocused
    pendingSearchExit = PendingSearchExit(
      destinationTab: destinationTab,
      destination: destination,
      createsThread: createsThread
    )
    searchFocusRequested = false

    if !requiresFocusSettlement {
      completePendingSearchExit()
    }
  }

  private func searchFocusChanged(_ isFocused: Bool) {
    isSearchFieldFocused = isFocused
    if !isFocused {
      completePendingSearchExit()
    }
  }

  private func closeSearch() {
    searchInteractionRevision &+= 1
    pendingSearchExit = nil
    searchFocusRequested = false
  }

  private func openSearchResult(_ peer: Peer, _ destination: Destination) {
    guard isSearchRootSelected else { return }
    ExperimentalHomeNavigationPerformance.beginChatOpen(peer: peer, source: "search")
    searchFocusRequested = false
    router.push(destination, for: .search)
  }

  private func completePendingSearchExit() {
    guard !isSearchFieldFocused,
          !isSearchKeyboardVisible,
          let pendingSearchExit
    else { return }
    self.pendingSearchExit = nil

    if let destination = pendingSearchExit.destination {
      router[pendingSearchExit.destinationTab.appTab] = [destination]
    }
    selectRootTab(pendingSearchExit.destinationTab, previousRootTab: .search)

    if pendingSearchExit.createsThread {
      createThreadInstantly(spaceId: nav.activeSpaceId)
    }
  }

  private func configureHomeList() {
    let homeScope = ExperimentalHomeChatScope(rawValue: homeChatScopeRaw) ?? .all
    let sortMode = ExperimentalHomeSortMode(rawValue: sortModeRaw) ?? .recentActivity
    homeListStore.setConfiguration(ExperimentalHomeListConfiguration(
      spaceID: nav.activeSpaceId,
      includeSpaceChatsInHome: homeScope == .all,
      homeSpaceExclusions: homeSpaceExclusions,
      inboxSort: sortMode.chatListSort,
      allChatsFilter: ChatListFilter(rawValue: allChatsFilterRaw) ?? .all
    ))
  }

  private func chatsRoot(rootTab: RootTab) -> some View {
    return ExperimentalHomeView(
      initialTab: rootTab == .inbox ? .inbox : .allChats,
      allChatsFilter: ChatListFilter(rawValue: allChatsFilterRaw) ?? .all
    )
  }

  @ViewBuilder
  private func activeSpacePicker(
    selectedSpaceId: Binding<Int64?>
  ) -> some View {
    let picker = SpacePickerMenu(
      compactSpaceList: compactSpaceList,
      realtimeState: realtimeState,
      selectedSpaceId: selectedSpaceId,
      onSelectHome: {
        selectedSpaceId.wrappedValue = nil
        returnToCurrentTabRootAfterSpaceChange()
      },
      onSelectSpace: { space in
        if selectedSpaceId.wrappedValue != space.id {
          selectedSpaceId.wrappedValue = space.id
        }
        returnToCurrentTabRootAfterSpaceChange()
      },
      onCreateSpace: {
        router.presentSheet(.createSpace)
      },
      showsConnectionStateInTitle: false
    )

    picker
      .offset(x: activeSpace == nil ? -2 : 0)
  }

  private func returnToCurrentTabRootAfterSpaceChange() {
    if usesIPadSplitView {
      resetIPadNavigationForWorkspaceChange()
    } else {
      router.popToRoot(for: router.selectedTab)
    }
  }

  private func selectSpaceInHome(_ spaceID: Int64) {
    let targetTab = router.selectedTab.experimentalHomeFallbackTab
    nav.activeSpaceId = spaceID
    if usesIPadSplitView {
      resetIPadNavigationForWorkspaceChange()
    } else {
      router.popToRoot(for: targetTab)
      if router.selectedTab != targetTab {
        router.selectedTab = targetTab
      }
    }
  }

  private func resetIPadNavigationForWorkspaceChange() {
    IPadNavigationLane.resetBoundary(in: router)
  }

  private func migrateLegacySpaceDestination(_ spaceID: Int64) {
    migrateLegacySpaceDestinationIfNeeded(expectedSpaceID: spaceID)
  }

  private func migrateLegacySpaceDestinationIfNeeded(expectedSpaceID: Int64? = nil) {
    let sourceTab = router.selectedTab
    let sourcePath = router[sourceTab]
    let legacySpaceIDs = sourcePath.compactMap(\.legacySpaceID)
    guard let spaceID = expectedSpaceID ?? legacySpaceIDs.first,
          legacySpaceIDs.contains(spaceID)
    else { return }

    let migratedPath = sourcePath.filter { $0.legacySpaceID == nil }
    nav.activeSpaceId = spaceID
    if usesIPadSplitView {
      IPadNavigationLane.resetBoundary(in: router, path: migratedPath)
      return
    }

    let targetTab = sourceTab.experimentalHomeFallbackTab
    router[targetTab] = migratedPath
    if sourceTab != targetTab {
      router[sourceTab] = []
      router.selectedTab = targetTab
    }
  }

  private func restoreSceneHomeStateIfNeeded() {
    guard !didRestoreSceneHomeState else { return }
    didRestoreSceneHomeState = true

    let restoredSpaceID: Int64?
    if let sceneSpaceID = Int64(sceneActiveSpaceIDRaw) {
      restoredSpaceID = sceneSpaceID
    } else if !didMigrateActiveSpaceToScene {
      restoredSpaceID = ExperimentalNavigationModel.loadLegacyActiveSpaceId()
      didMigrateActiveSpaceToScene = true
      sceneActiveSpaceIDRaw = restoredSpaceID.map(String.init) ?? ""
    } else {
      restoredSpaceID = nil
    }

    if case let .externalChat(_, contextSpaceID, _) = router.selectedTabPath.last {
      nav.activeSpaceId = restoredSpaceID == contextSpaceID ? restoredSpaceID : nil
    } else {
      nav.activeSpaceId = restoredSpaceID
    }
  }

  private func ensureActiveSpaceExists() {
    guard let activeSpaceID = nav.activeSpaceId else { return }
    guard !compactSpaceList.spaces.isEmpty else { return }
    if !compactSpaceList.spaces.contains(where: { $0.id == activeSpaceID }) {
      nav.activeSpaceId = nil
      if usesIPadSplitView {
        resetIPadNavigationForWorkspaceChange()
      }
    }
  }

  private func loadHomeDataOnAppear() async {
    guard nav.consumeNeedsHomeBootstrap() else { return }
    homeBootstrapRetryTask?.cancel()
    homeBootstrapRetryTask = nil
    homeBootstrapGeneration &+= 1
    let generation = homeBootstrapGeneration
    let task = Task { @MainActor in
      await performHomeBootstrap(generation: generation)
    }
    homeBootstrapTask = task

    let outcome = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }

    guard homeBootstrapGeneration == generation else { return }
    homeBootstrapTask = nil

    switch outcome {
    case .success:
      homeBootstrapRetryAttempt = 0
    case .failure:
      nav.resetHomeDataState()
      scheduleHomeBootstrapRetry(generation: generation, accountID: auth.currentUserId)
    case .cancelled:
      nav.resetHomeDataState()
    }
  }

  private func performHomeBootstrap(generation: UInt64) async -> HomeBootstrapOutcome {
    guard generation == homeBootstrapGeneration, !Task.isCancelled else { return .cancelled }
    notificationHandler.setAuthenticated(value: true)

    guard generation == homeBootstrapGeneration, !Task.isCancelled else { return .cancelled }
    let localSpaces = await performHomeLoadRequest(
      stage: .localInitialRead,
      operation: { try await InviteDirectory.spaces(database: compactSpaceList.db) }
    )
    guard generation == homeBootstrapGeneration, !Task.isCancelled else { return .cancelled }
    guard localSpaces.succeeded, let spaces = localSpaces.value else { return .failure }
    nav.pruneDialogFetchState(validSpaceIds: Set(spaces.map(\.id)))
    reconcileActiveSpace(with: spaces)
    return .success
  }

  private func reconcileActiveSpace(with spaces: [Space]) {
    guard let activeSpaceID = nav.activeSpaceId else { return }
    if !spaces.contains(where: { $0.id == activeSpaceID }) {
      nav.activeSpaceId = nil
      if usesIPadSplitView {
        resetIPadNavigationForWorkspaceChange()
      }
    }
  }

  private func performHomeLoadRequest<Value>(
    stage: ExperimentalHomeLoadStage,
    operation: () async throws -> Value
  ) async -> (succeeded: Bool, value: Value?) {
    do {
      return (true, try await operation())
    } catch {
      ExperimentalHomeLoadDiagnostics.reportFailure(
        stage: stage,
        error: error,
        taskIsCancelled: Task.isCancelled,
        context: homeLoadDiagnosticContext()
      )
      return (false, nil)
    }
  }

  private func homeLoadDiagnosticContext() -> ExperimentalHomeLoadDiagnosticContext {
    ExperimentalHomeLoadDiagnosticContext(
      surface: nav.activeSpaceId == nil ? .home : .space,
      cachedChatCount: homeListStore.state.presentation.allChatCount,
      authAvailable: auth.currentUserId != nil,
      realtimeState: realtimeState.connectionState
    )
  }

  private func openHomeDestination(_ destination: Destination) {
    if usesIPadSplitView {
      router[IPadNavigationLane.canonicalTab] = [destination]
    } else {
      router.push(destination, for: router.selectedTab)
    }
  }

  private func createThreadInstantly(spaceId: Int64?) {
    guard !isCreatingThread else { return }
    guard let currentUserId = auth.currentUserId else {
      ToastManager.shared.showToast(
        "You're signed out. Please log in again.",
        type: .error,
        systemImage: "exclamationmark.triangle"
      )
      return
    }

    isCreatingThread = true

    Task {
      do {
        let chatId = try await realtimeV2.createThreadLocally(
          title: "",
          emoji: nil,
          isPublic: false,
          spaceId: spaceId,
          participants: [currentUserId]
        )
        let peer: Peer = .thread(id: chatId)

        // Match macOS: a newly-created thread immediately belongs to Inbox.
        await realtimeV2.sendQueued(
          .updateDialogOpen(peerId: peer, open: true, requiresChatCreated: true)
        )

        await MainActor.run {
          isCreatingThread = false
          openHomeDestination(.chat(peer: peer))
        }
      } catch {
        await MainActor.run {
          isCreatingThread = false
          ToastManager.shared.showToast(
            "Failed to create thread.",
            type: .error,
            systemImage: "exclamationmark.triangle"
          )
          Log.shared.error("Failed to create thread", error: error)
        }
      }
    }
  }

  private func cleanUpOpenChats() {
    guard !isCleaningOpenChats else { return }
    guard let currentUserID = auth.currentUserId else {
      ToastManager.shared.showToast(
        "You're signed out. Please log in again.",
        type: .error,
        systemImage: "exclamationmark.triangle"
      )
      return
    }
    guard case .connected = realtimeState.connectionState else {
      ToastManager.shared.showToast(
        "Cleanup isn’t available right now.",
        type: .info,
        systemImage: "wifi.exclamationmark"
      )
      return
    }

    isCleaningOpenChats = true
    Task { @MainActor in
      defer { isCleaningOpenChats = false }

      do {
        // Reconcile first so deleting a locally empty folder starts from the
        // current server snapshot rather than an old folder projection.
        let expectedUserState = try await GRDBSyncStorage(db: compactSpaceList.db)
          .getBucketState(for: .user)
        _ = try await realtimeV2.send(.getChats(expectedUserBucketState: expectedUserState))

        let now = Date()
        let candidates = try await OpenChatsCleanup.candidates(
          policy: .manual,
          now: now,
          currentUserID: currentUserID
        )
        let commit = try await OpenChatsCleanup.commit(
          policy: .manual,
          now: now,
          currentUserID: currentUserID,
          dialogIDs: candidates.map(\.dialogID)
        )

        for peer in commit.closedPeers {
          _ = await realtimeV2.sendQueued(.updateDialogOpen(peerId: peer, open: false))
        }
        for folderID in commit.emptyFolderIDs {
          _ = await realtimeV2.sendQueued(.deleteDialogFolder(
            folderId: folderID,
            disposition: .keepDialogs
          ))
        }

        ToastManager.shared.showToast(
          openChatsCleanupResultMessage(
            chats: commit.closedPeers.count,
            folders: commit.emptyFolderIDs.count
          ),
          type: .success,
          systemImage: "eraser.line.dashed"
        )
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to clean up Open Chats", error: error)
        ToastManager.shared.showToast(
          "Couldn’t clean up chats and folders.",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }

  private func openChatsCleanupResultMessage(chats: Int, folders: Int) -> String {
    switch (chats, folders) {
    case (0, 0):
      "No chats or folders to clean up."
    case (let chats, 0):
      "Cleaned up \(chats) \(chats == 1 ? "chat" : "chats")."
    case (0, let folders):
      "Deleted \(folders) empty \(folders == 1 ? "folder" : "folders")."
    case let (chats, folders):
      "Cleaned up \(chats) \(chats == 1 ? "chat" : "chats") and deleted \(folders) empty \(folders == 1 ? "folder" : "folders")."
    }
  }

  @ToolbarContentBuilder
  private func experimentalToolbarContent() -> some ToolbarContent {
    if #available(iOS 26.0, *) {
      ToolbarItem(placement: .topBarLeading) {
        rootToolbarTitle
      }
      .sharedBackgroundVisibility(.hidden)

      if usesIPadSplitView {
        ToolbarItem(placement: .topBarTrailing) {
          newChatButton(activeSpaceId: nav.activeSpaceId)
        }
      }

      if let connectionState = realtimeState.displayedConnectionState {
        ToolbarItem(placement: .topBarTrailing) {
          connectionProgressIndicator(connectionState)
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)
      }

      ToolbarItem(placement: .topBarTrailing) {
        overflowMenu()
      }

      ToolbarSpacer(.fixed, placement: .topBarTrailing)

      ToolbarItem(placement: .topBarTrailing) {
        accountButton()
      }
      .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .topBarLeading) {
        rootToolbarTitle
      }

      ToolbarItemGroup(placement: .topBarTrailing) {
        newChatButton(activeSpaceId: nav.activeSpaceId)
        if let connectionState = realtimeState.displayedConnectionState {
          connectionProgressIndicator(connectionState)
        }
        overflowMenu()
      }

      ToolbarItem(placement: .topBarTrailing) {
        accountButton()
      }
    }
  }

  private func newChatButton(activeSpaceId: Int64?) -> some View {
    Button {
      createThreadInstantly(spaceId: activeSpaceId)
    } label: {
      Image(systemName: "square.and.pencil")
    }
    .disabled(isCreatingThread)
    .accessibilityLabel("New Thread")
  }

  @ViewBuilder
  private var rootToolbarTitle: some View {
    if isSearchRootSelected {
      HStack(spacing: 4) {
        Text("Search")
          .font(.title.weight(.bold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
      .contentShape(Rectangle())
      .accessibilityAddTraits(.isHeader)
    } else {
      activeSpacePicker(selectedSpaceId: $nav.activeSpaceId)
    }
  }

  private var showsAllChatsFilter: Bool {
    if usesIPadSplitView {
      return iPadSidebarScope == .allChats
    }
    return RootTab(appTab: router.selectedTab) == .allChats && router.selectedTabPath.isEmpty
  }

  private var showsOpenChatsCleanup: Bool {
    if usesIPadSplitView {
      return iPadSidebarScope == .open
    }
    return RootTab(appTab: router.selectedTab) == .inbox && router.selectedTabPath.isEmpty
  }

  private func connectionProgressIndicator(
    _ connectionState: RealtimeConnectionState
  ) -> some View {
    ExperimentalConnectionToolbarSpinner(lineWidth: 2.25)
      .frame(width: 18, height: 18)
      .frame(width: 28, height: 28)
      .fixedSize(horizontal: true, vertical: true)
      .accessibilityLabel(connectionState.title)
  }

  private func accountButton() -> some View {
    Button {
      router.presentSheet(.settings)
    } label: {
      ExperimentalProfileToolbarLabel()
    }
    .buttonStyle(.plain)
    .accessibilityLabel("App Settings")
  }

  private func overflowMenu() -> some View {
    ExperimentalOverflowMenuButton(
      notificationSubtitle: String(localized: notificationSettings.mode.valueTitle),
      notificationSystemImage: notificationSettings.mode.systemImage,
      itemSize: selectedChatItemRenderMode,
      sortMode: ExperimentalHomeSortMode(rawValue: sortModeRaw) ?? .recentActivity,
      allChatsFilter: showsAllChatsFilter
        ? (ChatListFilter(rawValue: allChatsFilterRaw) ?? .all)
        : nil,
      homeSpaceExclusionMenu: homeSpaceExclusionMenu,
      activeSpaceName: activeSpace?.displayName,
      onNotifications: {
        isNotificationSettingsPresented = true
      },
      onArchive: {
        openHomeDestination(.archived)
      },
      onSelectItemSize: { mode in
        chatItemRenderModeRaw = mode.rawValue
      },
      onSelectSortMode: { mode in
        sortModeRaw = mode.rawValue
      },
      onSelectAllChatsFilter: { filter in
        allChatsFilterRaw = filter.rawValue
      },
      onToggleHomeSpaceExclusion: toggleHomeSpaceExclusion,
      onCleanup: showsOpenChatsCleanup ? cleanUpOpenChats : nil,
      onInvite: {
        if let activeSpace {
          router.presentSheet(.addMember(spaceId: activeSpace.id))
        } else {
          router.presentSheet(.inviteToInline)
        }
      },
      onMembers: activeSpace.map { space in
        { router.presentSheet(.members(spaceId: space.id)) }
      },
      onManage: activeSpace.map { space in
        { openHomeDestination(.spaceSettings(spaceId: space.id)) }
      }
    )
    .frame(width: 28, height: 28)
    .accessibilityLabel(usesIPadSplitView ? "Chat List Options" : "More")
    .popover(isPresented: $isNotificationSettingsPresented) {
      NotificationSettingsPopoverContent(
        notificationSettings: notificationSettings,
        onSelection: { isNotificationSettingsPresented = false }
      )
      .frame(idealWidth: 360, idealHeight: 480)
      .presentationCompactAdaptation(.popover)
    }
  }

  private var selectedChatItemRenderMode: ExperimentalHomeChatItemRenderMode {
    let mode = ExperimentalHomeChatItemRenderMode(rawValue: chatItemRenderModeRaw) ?? .twoLineLastMessage
    return mode == .oneLineLastMessage ? .twoLineLastMessage : mode
  }

  private var homeSpaceExclusions: HomeSpaceExclusions {
    HomeSpaceExclusions(rawValue: excludedHomeSpaceIDsRaw)
  }

  private var homeSpaceExclusionMenu: ExperimentalHomeSpaceExclusionMenu? {
    guard showsAllChatsFilter, nav.activeSpaceId == nil else { return nil }
    let spaces = compactSpaceList.spaces
      .map { ExperimentalHomeSpaceExclusionOption(id: $0.id, title: $0.displayName) }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    guard spaces.isEmpty == false else { return nil }
    return ExperimentalHomeSpaceExclusionMenu(
      spaces: spaces,
      excludedSpaceIDs: homeSpaceExclusions.spaceIDs
    )
  }

  private func toggleHomeSpaceExclusion(_ spaceID: Int64) {
    excludedHomeSpaceIDsRaw = homeSpaceExclusions.toggling(spaceID).rawValue
  }

  private var activeSpace: Space? {
    guard let activeSpaceId = nav.activeSpaceId else { return nil }
    return compactSpaceList.spaces.first(where: { $0.id == activeSpaceId })
  }

  private func invalidateHomeBootstrap(
    resetProgress: Bool
  ) -> Task<HomeBootstrapOutcome, Never>? {
    homeBootstrapGeneration &+= 1
    let previousTask = homeBootstrapTask
    homeBootstrapTask = nil
    previousTask?.cancel()
    homeBootstrapRetryTask?.cancel()
    homeBootstrapRetryTask = nil
    if resetProgress {
      homeBootstrapRetryAttempt = 0
    }
    return previousTask
  }

  private func scheduleHomeBootstrapRetry(
    generation: UInt64,
    accountID: Int64?
  ) {
    guard homeBootstrapRetryAttempt == 0, homeBootstrapRetryTask == nil,
          let accountID
    else { return }
    homeBootstrapRetryAttempt = 1
    homeBootstrapRetryTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      guard generation == homeBootstrapGeneration,
            auth.currentUserId == accountID,
            !Task.isCancelled
      else { return }
      homeBootstrapRetryTask = nil
      await loadHomeDataOnAppear()
    }
  }

  private func refetchCoreDataAfterLocalDataCleared(
    after previousTask: Task<HomeBootstrapOutcome, Never>?
  ) async {
    await previousTask?.value
    await loadHomeDataOnAppear()
  }
}

private struct ExperimentalConnectionToolbarSpinner: UIViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme

  let lineWidth: CGFloat

  func makeUIView(context: Context) -> ExperimentalConnectionSpinnerView {
    let view = ExperimentalConnectionSpinnerView()
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ view: ExperimentalConnectionSpinnerView, context: Context) {
    view.update(
      color: colorScheme == .dark ? .white : .black,
      lineWidth: lineWidth
    )
  }
}

private final class ExperimentalConnectionSpinnerView: UIView {
  private static let animationKey = "inline.connection-spinner.rotation"
  private static let rotationDuration: CFTimeInterval = 0.65

  private let trackLayer = CAShapeLayer()
  private let arcLayer = CAShapeLayer()
  private var lineWidth: CGFloat = 2.25

  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false

    trackLayer.fillColor = UIColor.clear.cgColor
    arcLayer.fillColor = UIColor.clear.cgColor
    arcLayer.lineCap = .round
    arcLayer.strokeStart = 0
    arcLayer.strokeEnd = 0.72

    layer.addSublayer(trackLayer)
    layer.addSublayer(arcLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    startAnimatingIfNeeded()
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let layerBounds = bounds
    let circleBounds = layerBounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    let circlePath = UIBezierPath(ovalIn: circleBounds).cgPath

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.frame = layerBounds
    trackLayer.path = circlePath
    arcLayer.frame = layerBounds
    arcLayer.path = circlePath
    CATransaction.commit()

    startAnimatingIfNeeded()
  }

  func update(color: UIColor, lineWidth: CGFloat) {
    let resolvedColor = color.resolvedColor(with: traitCollection)
    self.lineWidth = lineWidth

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.strokeColor = resolvedColor.withAlphaComponent(0.14).cgColor
    trackLayer.lineWidth = lineWidth
    arcLayer.strokeColor = resolvedColor.cgColor
    arcLayer.lineWidth = lineWidth
    CATransaction.commit()

    setNeedsLayout()
    startAnimatingIfNeeded()
  }

  private func startAnimatingIfNeeded() {
    guard window != nil else { return }
    guard arcLayer.animation(forKey: Self.animationKey) == nil else { return }

    let layerTime = arcLayer.convertTime(CACurrentMediaTime(), from: nil)
    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
    animation.fromValue = 0
    animation.toValue = CGFloat.pi * 2
    animation.duration = Self.rotationDuration
    animation.repeatCount = .infinity
    // Align every recreated toolbar host to one continuous phase instead of restarting at zero.
    animation.beginTime = layerTime - layerTime.truncatingRemainder(dividingBy: Self.rotationDuration)
    animation.isRemovedOnCompletion = false
    arcLayer.add(animation, forKey: Self.animationKey)
  }
}

private struct ExperimentalHomeSpaceExclusionOption: Equatable, Identifiable {
  let id: Int64
  let title: String
}

private struct ExperimentalHomeSpaceExclusionMenu: Equatable {
  let spaces: [ExperimentalHomeSpaceExclusionOption]
  let excludedSpaceIDs: Set<Int64>
}

private struct ExperimentalOverflowMenuButton: UIViewRepresentable {
  let notificationSubtitle: String
  let notificationSystemImage: String
  let itemSize: ExperimentalHomeChatItemRenderMode
  let sortMode: ExperimentalHomeSortMode
  let allChatsFilter: ChatListFilter?
  let homeSpaceExclusionMenu: ExperimentalHomeSpaceExclusionMenu?
  let activeSpaceName: String?
  let onNotifications: () -> Void
  let onArchive: () -> Void
  let onSelectItemSize: (ExperimentalHomeChatItemRenderMode) -> Void
  let onSelectSortMode: (ExperimentalHomeSortMode) -> Void
  let onSelectAllChatsFilter: (ChatListFilter) -> Void
  let onToggleHomeSpaceExclusion: (Int64) -> Void
  let onCleanup: (() -> Void)?
  let onInvite: () -> Void
  let onMembers: (() -> Void)?
  let onManage: (() -> Void)?

  func makeUIView(context: Context) -> UIButton {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.plain()
    configuration.image = UIImage(systemName: "ellipsis")
    configuration.baseForegroundColor = .label
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.showsMenuAsPrimaryAction = true
    button.accessibilityLabel = "More"
    return button
  }

  func updateUIView(_ button: UIButton, context: Context) {
    button.menu = makeMenu()
  }

  private func makeMenu() -> UIMenu {
    let notifications = UIAction(
      title: "Notifications",
      subtitle: notificationSubtitle,
      image: UIImage(systemName: notificationSystemImage)
    ) { _ in
      onNotifications()
    }

    let archivedChats = UIAction(
      title: "Archived Chats",
      image: UIImage(systemName: "archivebox")
    ) { _ in
      onArchive()
    }
    let invite = UIAction(
      title: "Invite",
      image: UIImage(systemName: "person.badge.plus")
    ) { _ in
      onInvite()
    }
    let itemSizeMenu = UIMenu(
      title: "Item Size",
      subtitle: itemSize.title,
      image: UIImage(systemName: "textformat.size"),
      options: .singleSelection,
      children: ExperimentalHomeChatItemRenderMode.allCases.map { mode in
        UIAction(title: mode.title, state: mode == itemSize ? .on : .off) { _ in
          onSelectItemSize(mode)
        }
      }
    )
    let sortMenu = UIMenu(
      title: "Sort",
      subtitle: sortMode.title,
      image: UIImage(systemName: "arrow.up.arrow.down"),
      options: .singleSelection,
      children: ExperimentalHomeSortMode.allCases.map { mode in
        UIAction(title: mode.title, state: mode == sortMode ? .on : .off) { _ in
          onSelectSortMode(mode)
        }
      }
    )
    let filterMenu = allChatsFilter.map { currentFilter in
      UIMenu(
        title: "Filter",
        subtitle: currentFilter == .unread ? "Unread" : "All Chats",
        image: UIImage(systemName: "line.3.horizontal.decrease"),
        options: .singleSelection,
        children: ChatListFilter.allCases.map { filter in
          UIAction(
            title: filter == .unread ? "Unread" : "All Chats",
            state: filter == currentFilter ? .on : .off
          ) { _ in
            onSelectAllChatsFilter(filter)
          }
        }
      )
    }
    let excludedSpacesMenu = homeSpaceExclusionMenu.map { configuration in
      let excludedCount = configuration.spaces.filter {
        configuration.excludedSpaceIDs.contains($0.id)
      }.count
      let excludedSubtitle = switch excludedCount {
      case 0: "All spaces shown"
      case 1: "1 space excluded"
      default: "\(excludedCount) spaces excluded"
      }
      return UIMenu(
        title: "Exclude Spaces from Home",
        subtitle: excludedSubtitle,
        image: UIImage(systemName: "eye.slash"),
        children: configuration.spaces.map { space in
          UIAction(
            title: space.title,
            state: configuration.excludedSpaceIDs.contains(space.id) ? .on : .off
          ) { _ in
            onToggleHomeSpaceExclusion(space.id)
          }
        }
      )
    }
    let viewOptions = UIMenu(
      title: "View Options",
      image: UIImage(systemName: "slider.horizontal.3"),
      children: [itemSizeMenu, sortMenu] + (excludedSpacesMenu.map { [$0] } ?? [])
    )

    let viewSection = UIMenu(
      options: .displayInline,
      children: [notifications] + (filterMenu.map { [$0] } ?? []) + [viewOptions, archivedChats]
    )

    let cleanupSection = onCleanup.map { onCleanup in
      UIMenu(
        options: .displayInline,
        children: [
          UIAction(
            title: "Cleanup…",
            subtitle: "Closes inactive chats; deletes empty folders",
            image: UIImage(systemName: "eraser.line.dashed")
          ) { _ in
            onCleanup()
          },
        ]
      )
    }

    let spaceSection: UIMenu
    if let activeSpaceName, let onMembers, let onManage {
      spaceSection = UIMenu(
        title: activeSpaceName,
        options: .displayInline,
        children: [
          invite,
          UIAction(title: "Members", image: UIImage(systemName: "person.2")) { _ in onMembers() },
          UIAction(title: "Manage", image: UIImage(systemName: "gearshape.2")) { _ in onManage() },
        ]
      )
    } else {
      spaceSection = UIMenu(options: .displayInline, children: [invite])
    }

    return UIMenu(
      children: [viewSection] + (cleanupSection.map { [$0] } ?? []) + [spaceSection]
    )
  }
}

private extension View {
  @ViewBuilder
  func experimentalRootTitleDisplayMode() -> some View {
    if #available(iOS 26.0, *) {
      toolbarTitleDisplayMode(.inlineLarge)
    } else {
      navigationBarTitleDisplayMode(.inline)
    }
  }
}
