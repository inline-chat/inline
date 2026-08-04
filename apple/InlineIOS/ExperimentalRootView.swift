import Auth
import InlineKit
import InlineUI
import Logger
import QuartzCore
import RealtimeV2
import SwiftUI
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
  @State private var rootTab: RootTab = .allChats
  @State private var lastContentRootTab: RootTab = .allChats
  @State private var searchQuery = ""
  @State private var isCreatingThread = false
  @State private var isNotificationSettingsPresented = false
  @AppStorage("ios.experimental.root.selectedTab")
  private var persistedRootTabRaw = RootTab.allChats.rawValue
  @AppStorage("ios.experimental.root.didMigrateExplicitTabs")
  private var didMigrateExplicitTabs = false
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
          ExperimentalDestinationView(nav: bindableNav, destination: destination)
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
      migrateLegacyRootTabsIfNeeded()
      let restoredRootTab = RootTab(rawValue: persistedRootTabRaw) ?? .allChats
      let persistedTab = restoredRootTab == .newChat ? .allChats : restoredRootTab
      let routedTab = RootTab(appTab: bindableRouter.selectedTab)
      let hasPendingRoute = !bindableRouter[bindableRouter.selectedTab].isEmpty
      let desiredRootTab = hasPendingRoute ? routedTab : persistedTab
      let desiredTab = desiredRootTab.appTab
      configureHomeList()
      if bindableRouter.selectedTab != desiredTab {
        bindableRouter.selectedTab = desiredTab
      }
      rootTab = desiredRootTab
      lastContentRootTab = desiredRootTab

      if chatItemRenderModeRaw == ExperimentalHomeChatItemRenderMode.oneLineLastMessage.rawValue {
        chatItemRenderModeRaw = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue
      }
    }
    .onChange(of: bindableRouter.selectedTab) { _, newValue in
      let desiredRootTab = RootTab(appTab: newValue)
      let desiredTab = desiredRootTab.appTab
      if bindableRouter.selectedTab != desiredTab {
        bindableRouter.selectedTab = desiredTab
        return
      }
      if rootTab != desiredRootTab {
        rootTab = desiredRootTab
      }
      lastContentRootTab = desiredRootTab
      persistedRootTabRaw = desiredRootTab.rawValue
    }
    .onChange(of: rootTab) { _, newValue in
      if newValue == .newChat {
        createThreadInstantly(spaceId: nav.activeSpaceId)
        rootTab = lastContentRootTab
        return
      }

      let previousRootTab = lastContentRootTab
      ExperimentalHomeNavigationPerformance.measureTabSwitch(
        from: previousRootTab.rawValue,
        to: newValue.rawValue,
        rows: homeListStore.state.presentation.allChatCount
      )
      lastContentRootTab = newValue
      persistedRootTabRaw = newValue.rawValue
      let desiredTab = newValue.appTab
      if bindableRouter.selectedTab != desiredTab {
        bindableRouter.selectedTab = desiredTab
      }
      searchQuery = ""
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
      configureHomeList()
    }
    .onChange(of: sortModeRaw) { _, _ in
      configureHomeList()
    }
    .onChange(of: homeChatScopeRaw) { _, _ in
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

  private func rootPage(nav: ExperimentalNavigationModel) -> some View {
    @Bindable var bindableNav = nav

    return TabView(selection: $rootTab) {
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

  private func configureHomeList() {
    let homeScope = ExperimentalHomeChatScope(rawValue: homeChatScopeRaw) ?? .all
    let sortMode = ExperimentalHomeSortMode(rawValue: sortModeRaw) ?? .recentActivity
    homeListStore.setConfiguration(ExperimentalHomeListConfiguration(
      spaceID: nav.activeSpaceId,
      includeSpaceChatsInHome: homeScope == .all,
      sort: sortMode.chatListSort
    ))
  }

  private func chatsRoot(
    nav: ExperimentalNavigationModel,
    rootTab: RootTab
  ) -> some View {
    @Bindable var bindableNav = nav

    return ExperimentalHomeView(
      nav: bindableNav,
      initialTab: rootTab == .inbox ? .inbox : .allChats
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
        selectAllChatsAfterSpaceChange()
      },
      onSelectSpace: { space in
        if selectedSpaceId.wrappedValue != space.id {
          selectedSpaceId.wrappedValue = space.id
        }
        selectAllChatsAfterSpaceChange()
      },
      onCreateSpace: {
        router.push(.createSpace, for: router.selectedTab)
      },
      showsConnectionStateInTitle: false
    )

    picker
  }

  private func selectAllChatsAfterSpaceChange() {
    let previousTab = router.selectedTab
    router.popToRoot(for: previousTab)

    lastContentRootTab = .allChats
    persistedRootTabRaw = RootTab.allChats.rawValue
    rootTab = .allChats
    router.selectedTab = .allChats
    router.popToRoot(for: .allChats)
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
      title: "Sort By",
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
