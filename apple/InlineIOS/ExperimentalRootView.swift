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
        loadingView
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
    .toastView()
  }

  private var loadingView: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Unlocking...")
        .font(.headline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }
}

private struct ExperimentalAuthedRootView: View {
  @State private var nav = ExperimentalNavigationModel()
  @State private var homeActions = ExperimentalHomeActionCoordinator()
  @State private var translationCoordinator = ExperimentalHomeTranslationCoordinator()
  @State private var searchQuery = ""
  @State private var isCreatingThread = false
  @State private var isNotificationSettingsPresented = false
  @State private var didRestoreSceneHomeState = false
  @SceneStorage("ios.home.activeSpaceID.v1")
  private var sceneActiveSpaceIDRaw = ""
  @SceneStorage("ios.home.allChatsFilter.v1")
  private var allChatsFilterRaw = ChatListFilter.all.rawValue
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

  @Environment(Router.self) private var router
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
    _data = EnvironmentStateObject { env in
      DataManager(database: env.appDatabase)
    }

    _compactSpaceList = EnvironmentStateObject { env in
      CompactSpaceList(db: env.appDatabase)
    }
    _homeListStore = EnvironmentStateObject { env in
      ExperimentalHomeListStore(database: env.appDatabase)
    }
  }

  var body: some View {
    rootNavigation
      // The stack wraps the root TabView, so pushed destinations naturally replace
      // the tab surface. Legacy per-destination tab-bar hiding is unnecessary here.
      .environment(\.inlineHideTabBar, false)
      .environmentObject(data)
      .environmentObject(compactSpaceList)
      .environmentObject(homeListStore)
      .environment(homeActions)
      .onReceive(NotificationCenter.default.publisher(for: .localDataCleared)) { _ in
        nav.resetHomeDataState()
        homeListStore.refresh()
        Task {
          await refetchCoreDataAfterLocalDataCleared()
        }
      }
      .task {
        restoreSceneHomeStateIfNeeded()
        await loadHomeDataOnAppear()
      }
      .onChange(of: compactSpaceList.spaces) { _, _ in
        nav.pruneDialogFetchState(validSpaceIds: Set(compactSpaceList.spaces.map(\.id)))
        ensureActiveSpaceExists()
        Task { await refreshDialogsForCurrentSelection() }
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
    @Bindable var bindableNav = nav

    return NavigationStack(path: $bindableRouter[bindableRouter.selectedTab]) {
      rootPage(nav: bindableNav)
        .background(Color(.systemBackground))
        .experimentalRootTitleDisplayMode()
        .navigationTitle("")
        .toolbar {
          experimentalToolbarContent()
        }
        .navigationDestination(for: Destination.self) { destination in
          ExperimentalDestinationView(
            nav: bindableNav,
            destination: destination,
            onRetryHome: retryHomeData
          )
        }
    }
    // Prevent child views (e.g. ChatView) from leaking their toolbar appearance
    // back to Root when the shared stack pops.
    .toolbarColorScheme(colorScheme, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .sheet(item: $bindableRouter.presentedSheet) { sheet in
      if case .chatInfo = sheet {
        ExperimentalSheetView(sheet: sheet)
          .presentationDetents([.medium, .large])
      } else {
        ExperimentalSheetView(sheet: sheet)
      }
    }
    .onAppear {
      restoreSceneHomeStateIfNeeded()
      migrateLegacyRootTabsIfNeeded()
      let routedTab = RootTab(appTab: bindableRouter.selectedTab)
      let desiredRootTab = routedTab == .newChat ? .allChats : routedTab
      let desiredTab = desiredRootTab.appTab
      configureHomeList()
      if bindableRouter.selectedTab != desiredTab {
        bindableRouter.selectedTab = desiredTab
      }
      if chatItemRenderModeRaw == ExperimentalHomeChatItemRenderMode.oneLineLastMessage.rawValue {
        chatItemRenderModeRaw = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue
      }
    }
    .onChange(of: bindableRouter.selectedTab) { oldValue, newValue in
      let previousRootTab = RootTab(appTab: oldValue)
      let desiredRootTab = RootTab(appTab: newValue)
      let desiredTab = desiredRootTab.appTab
      if bindableRouter.selectedTab != desiredTab {
        bindableRouter.selectedTab = desiredTab
        return
      }
      guard previousRootTab != desiredRootTab else { return }
      ExperimentalHomeNavigationPerformance.measureTabSwitch(
        from: previousRootTab.rawValue,
        to: desiredRootTab.rawValue,
        rows: homeListStore.state.presentation.allChatCount
      )
      if previousRootTab == .search {
        searchQuery = ""
      }
    }
    .onChange(of: bindableRouter.selectedTabPath) { oldPath, newPath in
      guard let previousPeer = oldPath.last?.chatPeer,
            newPath.contains(where: { $0.chatPeer == previousPeer }) == false
      else { return }
      ExperimentalHomeNavigationPerformance.measureBackToHome(
        rows: homeListStore.state.presentation.allChatCount
      )
    }
    .onChange(of: nav.activeSpaceId) { _, _ in
      sceneActiveSpaceIDRaw = nav.activeSpaceId.map(String.init) ?? ""
      configureHomeList()
      Task { await reloadHomeData(forceDialogs: true) }
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

    return TabView(selection: rootTabSelection) {
      Tab("All Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .allChats) {
        chatsRoot(nav: bindableNav, rootTab: .allChats)
      }

      // TODO: Decide the badge color before bridging UIKit's global
      // `UITabBarItem.badgeColor`; SwiftUI's native tab badge has no tint API.
      Tab("Inbox", systemImage: "tray.full.fill", value: .inbox) {
        chatsRoot(nav: bindableNav, rootTab: .inbox)
      }
      .badge(homeListStore.state.presentation.inboxUnreadCount)

      Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
        ExperimentalSearchView(
          query: $searchQuery,
          activeSpaceId: bindableNav.activeSpaceId
        )
      }

      if #available(iOS 27.0, *) {
        Tab("New Thread", systemImage: "plus", value: .newChat, role: .prominent) {
          Color.clear
        }
      } else if #available(iOS 26.0, *) {
        // Search now owns the semantic `.search` role. iOS 26 has no separate
        // `.prominent` role, so New Thread remains a standard native tab action.
        Tab("New Thread", systemImage: "plus", value: .newChat) {
          Color.clear
        }
      }
    }
    .background(Color(.systemBackground))
  }

  private var rootTabSelection: Binding<RootTab> {
    Binding(
      get: { RootTab(appTab: router.selectedTab) },
      set: { newValue in
        if newValue == .newChat {
          createThreadInstantly(spaceId: nav.activeSpaceId)
        } else if router.selectedTab != newValue.appTab {
          router.selectedTab = newValue.appTab
        }
      }
    )
  }

  private func configureHomeList() {
    let homeScope = ExperimentalHomeChatScope(rawValue: homeChatScopeRaw) ?? .all
    let sortMode = ExperimentalHomeSortMode(rawValue: sortModeRaw) ?? .recentActivity
    homeListStore.setConfiguration(ExperimentalHomeListConfiguration(
      spaceID: nav.activeSpaceId,
      includeSpaceChatsInHome: homeScope == .all,
      inboxSort: sortMode.chatListSort,
      allChatsFilter: ChatListFilter(rawValue: allChatsFilterRaw) ?? .all
    ))
  }

  private func chatsRoot(
    nav: ExperimentalNavigationModel,
    rootTab: RootTab
  ) -> some View {
    @Bindable var bindableNav = nav

    return ExperimentalHomeView(
      nav: bindableNav,
      initialTab: rootTab == .inbox ? .inbox : .allChats,
      allChatsFilter: ChatListFilter(rawValue: allChatsFilterRaw) ?? .all,
      onRetry: retryHomeData
    )
  }

  @ViewBuilder
  private func activeSpacePicker(
    selectedSpaceId: Binding<Int64?>
  ) -> some View {
    let picker = SpacePickerMenu(
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
        router.push(.createSpace, for: router.selectedTab)
      },
      showsConnectionStateInTitle: false
    )

    picker
  }

  private func returnToCurrentTabRootAfterSpaceChange() {
    router.popToRoot(for: router.selectedTab)
  }

  private func restoreSceneHomeStateIfNeeded() {
    guard !didRestoreSceneHomeState else { return }
    didRestoreSceneHomeState = true

    if let restoredSpaceID = Int64(sceneActiveSpaceIDRaw) {
      nav.activeSpaceId = restoredSpaceID
    } else if !didMigrateActiveSpaceToScene {
      nav.activeSpaceId = ExperimentalNavigationModel.loadLegacyActiveSpaceId()
      didMigrateActiveSpaceToScene = true
      sceneActiveSpaceIDRaw = nav.activeSpaceId.map(String.init) ?? ""
    }
  }

  private func ensureActiveSpaceExists() {
    guard let activeSpaceID = nav.activeSpaceId else { return }
    guard !compactSpaceList.spaces.isEmpty else { return }
    if !compactSpaceList.spaces.contains(where: { $0.id == activeSpaceID }) {
      nav.activeSpaceId = nil
    }
  }

  private func loadHomeDataOnAppear() async {
    let shouldBootstrap = nav.consumeNeedsHomeBootstrap()
    await reloadHomeData(
      includeBootstrapData: shouldBootstrap,
      forceDialogs: nav.activeSpaceId != nil
    )
  }

  private func reloadHomeData(
    includeBootstrapData: Bool = false,
    forceDialogs: Bool = false
  ) async {
    let refreshRevision = nav.homeRefreshRevision
    var availableSpaces = compactSpaceList.spaces

    if includeBootstrapData {
      notificationHandler.setAuthenticated(value: true)

      do {
        _ = try await realtimeV2.send(.getMe())
        nav.recordHomeRefreshResult(requestID: "me", succeeded: true, revision: refreshRevision)
      } catch {
        nav.recordHomeRefreshResult(
          requestID: "me",
          succeeded: false,
          revision: refreshRevision,
          reportFailure: !Task.isCancelled
        )
        Log.shared.error("Failed to getMe", error: error)
      }

      do {
        _ = try await realtimeV2.send(.getChats())
        nav.recordHomeRefreshResult(requestID: "chats", succeeded: true, revision: refreshRevision)
      } catch {
        nav.recordHomeRefreshResult(
          requestID: "chats",
          succeeded: false,
          revision: refreshRevision,
          reportFailure: !Task.isCancelled
        )
        Log.shared.error("Failed to getChats", error: error)
      }

      do {
        availableSpaces = try await data.getSpaces()
        nav.pruneDialogFetchState(validSpaceIds: Set(availableSpaces.map(\.id)))
        nav.recordHomeRefreshResult(requestID: "spaces", succeeded: true, revision: refreshRevision)
      } catch {
        nav.recordHomeRefreshResult(
          requestID: "spaces",
          succeeded: false,
          revision: refreshRevision,
          reportFailure: !Task.isCancelled
        )
        Log.shared.error("Failed to getSpaces", error: error)
      }
    }

    guard !Task.isCancelled else { return }
    await refreshDialogsForCurrentSelection(
      force: forceDialogs,
      availableSpaces: availableSpaces,
      refreshRevision: refreshRevision
    )
  }

  private func refreshDialogsForCurrentSelection(
    force: Bool = false,
    availableSpaces: [Space]? = nil,
    refreshRevision: Int? = nil
  ) async {
    let revision = refreshRevision ?? nav.homeRefreshRevision
    if let spaceID = nav.activeSpaceId {
      await fetchDialogsIfNeeded(spaceID: spaceID, force: force, refreshRevision: revision)
    } else {
      // Cached rows remain interactive while remote reconciliation continues.
      let spaceIDs = (availableSpaces ?? compactSpaceList.spaces).map(\.id)
      for batchStart in stride(from: 0, to: spaceIDs.count, by: 4) {
        guard !Task.isCancelled, revision == nav.homeRefreshRevision else { return }
        let batchEnd = min(batchStart + 4, spaceIDs.count)
        let batch = spaceIDs[batchStart ..< batchEnd]
        await withTaskGroup(of: Void.self) { group in
          for spaceID in batch {
            group.addTask { @MainActor in
              await fetchDialogsIfNeeded(
                spaceID: spaceID,
                force: force,
                refreshRevision: revision
              )
            }
          }
        }
      }
    }
  }

  private func fetchDialogsIfNeeded(
    spaceID: Int64,
    force: Bool = false,
    refreshRevision: Int
  ) async {
    guard nav.beginDialogsFetchIfNeeded(spaceId: spaceID, force: force) else { return }
    do {
      try await data.getDialogs(spaceId: spaceID)
      nav.completeDialogsFetch(spaceId: spaceID, succeeded: true, revision: refreshRevision)
    } catch {
      nav.completeDialogsFetch(
        spaceId: spaceID,
        succeeded: false,
        revision: refreshRevision,
        reportFailure: !Task.isCancelled
      )
      Log.shared.error("Failed to get dialogs", error: error)
    }
  }

  private func retryHomeData() {
    nav.clearHomeRefreshFailures()
    homeListStore.refresh()
    Task {
      await reloadHomeData(includeBootstrapData: true, forceDialogs: true)
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
          router.push(.chat(peer: peer), for: router.selectedTab)
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

  @ToolbarContentBuilder
  private func experimentalToolbarContent() -> some ToolbarContent {
    if #available(iOS 26.0, *) {
      ToolbarItem(placement: .topBarLeading) {
        activeSpacePicker(selectedSpaceId: $nav.activeSpaceId)
      }
      .sharedBackgroundVisibility(.hidden)

      if showsAllChatsFilter {
        ToolbarItem(placement: .topBarTrailing) {
          allChatsFilterMenu()
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)
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
        activeSpacePicker(selectedSpaceId: $nav.activeSpaceId)
      }

      ToolbarItemGroup(placement: .topBarTrailing) {
        newChatButton(activeSpaceId: nav.activeSpaceId)
        if showsAllChatsFilter {
          allChatsFilterMenu()
        }
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

  private func allChatsFilterMenu() -> some View {
    let unreadOnly = Binding(
      get: { allChatsFilterRaw == ChatListFilter.unread.rawValue },
      set: { allChatsFilterRaw = $0 ? ChatListFilter.unread.rawValue : ChatListFilter.all.rawValue }
    )

    return Menu {
      Toggle(isOn: unreadOnly) {
        Label("Unread", systemImage: "envelope.badge")
      }
    } label: {
      Image(systemName: unreadOnly.wrappedValue
        ? "line.3.horizontal.decrease.circle.fill"
        : "line.3.horizontal.decrease.circle")
    }
    .accessibilityLabel("Filter All Chats")
    .accessibilityValue(unreadOnly.wrappedValue ? "Unread" : "All Chats")
  }

  private var showsAllChatsFilter: Bool {
    RootTab(appTab: router.selectedTab) == .allChats && router.selectedTabPath.isEmpty
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
      activeSpaceName: activeSpace?.displayName,
      onNotifications: {
        isNotificationSettingsPresented = true
      },
      onArchive: {
        router.push(.archived, for: router.selectedTab)
      },
      onSelectItemSize: { mode in
        chatItemRenderModeRaw = mode.rawValue
      },
      onSelectSortMode: { mode in
        sortModeRaw = mode.rawValue
      },
      onInvite: activeSpace.map { space in
        { router.presentSheet(.addMember(spaceId: space.id)) }
      },
      onMembers: activeSpace.map { space in
        { router.presentSheet(.members(spaceId: space.id)) }
      },
      onManage: activeSpace.map { space in
        { router.push(.spaceSettings(spaceId: space.id), for: router.selectedTab) }
      }
    )
    .frame(width: 28, height: 28)
    .accessibilityLabel("More")
    .popover(isPresented: $isNotificationSettingsPresented) {
      NotificationSettingsPopoverContent {
        isNotificationSettingsPresented = false
      }
      .frame(idealWidth: 360, idealHeight: 480)
      .presentationCompactAdaptation(.popover)
    }
  }

  private var selectedChatItemRenderMode: ExperimentalHomeChatItemRenderMode {
    let mode = ExperimentalHomeChatItemRenderMode(rawValue: chatItemRenderModeRaw) ?? .twoLineLastMessage
    return mode == .oneLineLastMessage ? .twoLineLastMessage : mode
  }

  private var activeSpace: Space? {
    guard let activeSpaceId = nav.activeSpaceId else { return nil }
    return compactSpaceList.spaces.first(where: { $0.id == activeSpaceId })
  }

  private func refetchCoreDataAfterLocalDataCleared() async {
    do {
      _ = try await realtimeV2.send(.getMe())
    } catch {
      Log.shared.error("Failed to reload current user after clearing local data", error: error)
    }

    do {
      _ = try await realtimeV2.send(.getChats())
    } catch {
      Log.shared.error("Failed to reload chats after clearing local data", error: error)
    }

    do {
      _ = try await data.getSpaces()
    } catch {
      Log.shared.error("Failed to reload spaces after clearing local data", error: error)
    }
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

private struct ExperimentalOverflowMenuButton: UIViewRepresentable {
  let notificationSubtitle: String
  let notificationSystemImage: String
  let itemSize: ExperimentalHomeChatItemRenderMode
  let sortMode: ExperimentalHomeSortMode
  let activeSpaceName: String?
  let onNotifications: () -> Void
  let onArchive: () -> Void
  let onSelectItemSize: (ExperimentalHomeChatItemRenderMode) -> Void
  let onSelectSortMode: (ExperimentalHomeSortMode) -> Void
  let onInvite: (() -> Void)?
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

    let notificationSection = UIMenu(options: .displayInline, children: [notifications])
    let archive = UIAction(
      title: "Archive",
      image: UIImage(systemName: "archivebox")
    ) { _ in
      onArchive()
    }
    let itemSizeMenu = UIMenu(
      title: "Item Size",
      options: [.displayInline, .singleSelection],
      children: ExperimentalHomeChatItemRenderMode.allCases.map { mode in
        UIAction(title: mode.title, state: mode == itemSize ? .on : .off) { _ in
          onSelectItemSize(mode)
        }
      }
    )
    let sortMenu = UIMenu(
      title: "Inbox Sort",
      options: [.displayInline, .singleSelection],
      children: ExperimentalHomeSortMode.allCases.map { mode in
        UIAction(title: mode.title, state: mode == sortMode ? .on : .off) { _ in
          onSelectSortMode(mode)
        }
      }
    )
    let viewOptions = UIMenu(
      title: "View Options",
      image: UIImage(systemName: "line.3.horizontal.decrease"),
      children: [itemSizeMenu, sortMenu]
    )

    var children: [UIMenuElement] = [notificationSection, archive, viewOptions]
    if let activeSpaceName,
       let onInvite,
       let onMembers,
       let onManage {
      children.append(UIMenu(
        title: activeSpaceName,
        options: .displayInline,
        children: [
          UIAction(title: "Invite", image: UIImage(systemName: "person.badge.plus")) { _ in onInvite() },
          UIAction(title: "Members", image: UIImage(systemName: "person.2")) { _ in onMembers() },
          UIAction(title: "Manage", image: UIImage(systemName: "gearshape.2")) { _ in onManage() },
        ]
      ))
    }

    return UIMenu(children: children)
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
