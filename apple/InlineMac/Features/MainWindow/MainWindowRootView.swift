import AppKit
import Combine
import InlineKit
import SwiftUI

/// Main app window
struct MainWindowRootView: View {
  @Environment(\.dependencies) private var dependencies
  @EnvironmentObject private var viewModel: MainWindowViewModel

  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var forwardMessages = ForwardMessagesPresenter()
  @State private var overlay = OverlayManager()
  @State private var commandBarRegistry = CommandBarRegistry()
  @State private var sidebarViewModel: SidebarViewModel
  @State private var nativeTab = NativeWindowTabModel()
  @State private var nativeTabShortcutUnsubscribe: (() -> Void)?
  @State private var topLevelRoute: TopLevelRoute = .loading
  private let nav3: Nav3
  private let chatOpenPreloader: Nav3ChatOpenPreloadBridge
  private let keyMonitor: KeyMonitor
  private let windowID: UUID

  private var windowDependencies: AppDependencies? {
    guard var dependencies else { return nil }
    dependencies.nav3 = nav3
    dependencies.nav3ChatOpenPreloader = chatOpenPreloader
    dependencies.forwardMessages = forwardMessages
    dependencies.keyMonitor = keyMonitor
    dependencies.overlay = overlay
    return dependencies
  }

  init(
    nav3: Nav3,
    initialTopLevelRoute: TopLevelRoute = .loading,
    chatOpenPreloader: Nav3ChatOpenPreloadBridge,
    keyMonitor: KeyMonitor,
    windowID: UUID = UUID()
  ) {
    self.nav3 = nav3
    self.chatOpenPreloader = chatOpenPreloader
    self.keyMonitor = keyMonitor
    self.windowID = windowID
    let settings = AppSettings.shared
    settings.resolveSidebarModeForCurrentAccount()
    let sidebarMode: SidebarViewModel.ContentMode = settings.sidebarAsInbox ? .inbox : .chatList
    let sidebarSort: SidebarSortMode = settings.sidebarAsInbox ? settings.sidebarSort : .recentActivity
    _sidebarViewModel = State(initialValue: SidebarViewModel(
      db: AppDatabase.shared,
      startsObserving: initialTopLevelRoute == .main,
      selectedSpaceId: nav3.selectedSpaceId,
      mode: sidebarMode,
      sortMode: sidebarSort,
      temporaryPeer: nav3.currentReplyThreadPeer ?? nav3.currentRoute.selectedPeer
    ))
    _topLevelRoute = State(initialValue: initialTopLevelRoute)
  }

  var body: some View {
    topLevelContent
    .environment(dependencies: windowDependencies)
    .environment(\.nav, nav3)
    .environment(\.mainWindowID, windowID)
    .environment(\.commandBarRegistry, commandBarRegistry)
    .environment(sidebarViewModel)
    .registerMainWindow(id: windowID, toastPresenter: overlay) { destination in
      nav3.open(destination.route)
    } openCommandBar: {
      nav3.openCommandBar()
    } toggleCommandBar: {
      nav3.toggleCommandBar()
    } toggleSidebar: {
      toggleSidebar()
    } createNewThread: {
      guard let dependencies = windowDependencies,
            dependencies.viewModel.topLevelRoute == .main
      else { return }
      NewThreadAction.start(dependencies: dependencies, spaceId: nav3.selectedSpaceId)
    } goBack: {
      nav3.goBack()
    } goForward: {
      nav3.goForward()
    } canGoBack: {
      nav3.canGoBack
    } canGoForward: {
      nav3.canGoForward
    } selectedPeer: {
      activeSelectedPeer
    } isViewingChat: { peer in
      // Read the route directly; menu/selection snapshots can lag a transition.
      guard viewModel.topLevelRoute == .main else { return false }
      return nav3.currentRoute.selectedPeer == peer || nav3.currentReplyThreadPeer == peer
    }
    .nativeWindowTab(title: nativeTab.title, icon: nativeTab.iconPeer)
    .onAppear {
      syncTopLevelRoute(viewModel.topLevelRoute)
      nativeTab.update(peer: currentSelectedPeer)
      syncCurrentPeer()
      syncSpaceMenuContext()
      installNativeTabShortcuts()
    }
    .onReceive(viewModel.$topLevelRoute) { route in
      syncTopLevelRoute(route)
      syncCurrentPeer()
      syncSpaceMenuContext()
    }
    .onChange(of: nav3.currentRoute) { _, _ in
      nativeTab.update(peer: currentSelectedPeer)
      syncCurrentPeer()
    }
    .onChange(of: nav3.selectedSpaceId) { _, _ in
      syncSpaceMenuContext()
    }
    .onChange(of: sidebarViewModel.spaces) { _, _ in
      syncSpaceMenuContext()
    }
    .onDisappear {
      chatOpenPreloader.cancelPendingOpen()
      nativeTab.update(peer: nil)
      MainWindowOpenCoordinator.shared.updateSelectedPeer(id: windowID, peer: nil)
      removeNativeTabShortcuts()
      MainWindowOpenCoordinator.shared.unregisterWindow(id: windowID)
    }
  }

  private func installNativeTabShortcuts() {
    guard nativeTabShortcutUnsubscribe == nil else { return }

    nativeTabShortcutUnsubscribe = keyMonitor.addCommandNumberHandler(key: "native_window_tabs_\(windowID)") { event in
      guard let char = event.charactersIgnoringModifiers?.first,
            let position = Int(String(char)),
            (1 ... 9).contains(position)
      else { return false }

      return MainWindowOpenCoordinator.shared.selectTab(at: position)
    }
  }

  private func removeNativeTabShortcuts() {
    nativeTabShortcutUnsubscribe?()
    nativeTabShortcutUnsubscribe = nil
  }

  private var showsMain: Bool {
    topLevelRoute == .main
  }

  @ViewBuilder private var topLevelContent: some View {
    switch topLevelRoute {
    case .loading:
      MainWindowLoadingView()

    case .onboarding:
      Onboarding(
        allowsBackgroundWindowDrag: true,
        initialRoute: viewModel.onboardingInitialRoute
      )

    case .main:
      MainWindowRoot(
        columnVisibility: $columnVisibility,
        nav3: nav3,
        dependencies: windowDependencies,
        toggleSidebar: toggleSidebar
      )
    }
  }

  private func syncTopLevelRoute(_ route: TopLevelRoute) {
    if route == .main {
      AppSettings.shared.resolveSidebarModeForCurrentAccount()
      MacPermissions.ensureNotificationAuthorizationIfNeeded()
      sidebarViewModel.setTemporaryPeer(
        nav3.currentReplyThreadPeer ?? nav3.currentRoute.selectedPeer
      )
      sidebarViewModel.start(
        selectedSpaceId: nav3.selectedSpaceId,
        mode: sidebarMode,
        sortMode: sidebarSort
      )
      if let dependencies {
        dependencies.session.fetchInitialDataIfNeeded(dependencies: dependencies)
      }
    }

    guard topLevelRoute != route else { return }

    topLevelRoute = route
    if route != .main {
      chatOpenPreloader.cancelPendingOpen()
    }
    if route == .onboarding {
      nav3.reset()
    }
  }

  private func toggleSidebar() {
    switch columnVisibility {
    case .detailOnly:
      columnVisibility = .all
    default:
      columnVisibility = .detailOnly
    }
  }

  private func syncCurrentPeer() {
    let peer = activeSelectedPeer
    MainWindowOpenCoordinator.shared.updateSelectedPeer(id: windowID, peer: peer)
    guard let peer else { return }
    SidebarCleanup.shared.markOpened(peer)
  }

  private func syncSpaceMenuContext() {
    guard showsMain else {
      MainWindowOpenCoordinator.shared.unregisterSpaceMenuContext(id: windowID)
      return
    }
    MainWindowOpenCoordinator.shared.updateSpaceMenuContext(
      id: windowID,
      context: SpaceMenuContext(
        selectedSpaceID: nav3.selectedSpaceId,
        spaces: sidebarViewModel.spaces.map { .init(id: $0.id, name: $0.displayName) },
        selectHome: { nav3.selectHome() },
        selectSpace: { nav3.selectSpace($0) },
        createSpace: { nav3.open(.createSpace) },
        showSettings: { nav3.open(.spaceSettings(spaceId: $0)) },
        showMembers: { nav3.open(.members(spaceId: $0)) },
        showIntegrations: { nav3.open(.spaceIntegrations(spaceId: $0)) },
        showGrid: { nav3.open(.grid(spaceId: $0)) },
        invitePeople: { nav3.beginInvite(spaceId: $0) }
      )
    )
  }

  private var activeSelectedPeer: Peer? {
    showsMain ? currentSelectedPeer : nil
  }

  private var currentSelectedPeer: Peer? {
    nav3.currentRoute.selectedPeer
  }

  private var sidebarMode: SidebarViewModel.ContentMode {
    AppSettings.shared.sidebarAsInbox ? .inbox : .chatList
  }

  private var sidebarSort: SidebarSortMode {
    AppSettings.shared.sidebarAsInbox ? AppSettings.shared.sidebarSort : .recentActivity
  }
}

@MainActor
@Observable
private final class NativeWindowTabModel {
  var title: String?
  var iconPeer: ChatIcon.PeerType?

  @ObservationIgnored private var peer: Peer?
  @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

  func update(peer: Peer?) {
    guard self.peer != peer else { return }

    self.peer = peer
    cancellables.removeAll()
    title = "Inline"
    iconPeer = nil

    guard let peer else { return }

    switch peer {
    case let .user(id):
      ObjectCache.shared.getUserPublisher(id: id)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          self?.sync()
        }
        .store(in: &cancellables)

    case let .thread(id):
      ObjectCache.shared.getChatPublisher(id: id)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          self?.sync()
        }
        .store(in: &cancellables)
    }

    sync()
  }

  private func sync() {
    switch peer {
    case let .user(id):
      guard let userInfo = ObjectCache.shared.getUser(id: id) else {
        title = "Direct Message"
        iconPeer = nil
        return
      }

      title = userInfo.user.displayName
      iconPeer = .user(userInfo)

    case let .thread(id):
      guard let chat = ObjectCache.shared.getChat(id: id) else {
        title = "Chat"
        iconPeer = nil
        return
      }

      title = ReplyThreadTitleFallback.title(for: chat, anchorText: nil)
      iconPeer = .chat(chat)

    case .none:
      title = nil
      iconPeer = nil
    }
  }
}

private struct MainWindowLoadingView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Loading...")
        .font(.headline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
  }
}

private struct MainWindowRoot: View {
  @Binding var columnVisibility: NavigationSplitViewVisibility

  let nav3: Nav3
  let dependencies: AppDependencies?
  let toggleSidebar: () -> Void

  var body: some View {
    ZStack(alignment: .top) {
      NavigationSplitView(columnVisibility: $columnVisibility) {
        SidebarView(
          isCollapsed: isSidebarCollapsed
        )
        .navigationSplitViewColumnWidth(
          min: Theme.minimumSidebarWidth,
          ideal: Theme.idealSidebarWidth,
          max: Theme.maximumSidebarWidth
        )
      } detail: {
        MainContentView()
          .toastOverlayHost(dependencies?.overlay)
      }
      .toolbar {
        MainWindowToolbar(nav: nav3)
      }

      CommandBar()
    }
    .modifier(ForwardMessagesPresentation(dependencies: dependencies))
    .onAppear {
      updateWindowMinSize()
    }
    .onChange(of: isSidebarCollapsed) { _, _ in
      updateWindowMinSize()
    }
    .onChange(of: nav3.currentReplyThreadPeer) { _, _ in
      updateWindowMinSize()
    }
  }

  private var isSidebarCollapsed: Bool {
    if case .detailOnly = columnVisibility {
      return true
    }
    return false
  }

  private func updateWindowMinSize() {
    var size = isSidebarCollapsed
      ? MainWindowController.minSizeWithoutSidebar
      : MainWindowController.minSizeWithSidebar

    if nav3.currentReplyThreadPeer != nil {
      size.width = max(
        size.width,
        ReplyThreadPaneMetrics.minimumWindowWidth(isSidebarCollapsed: isSidebarCollapsed)
      )
    }

    dependencies?.appBridge.setWindowMinSize(size)
  }
}

/// Per window environments
extension EnvironmentValues {
  @Entry var nav = Nav3.default
  @Entry var mainWindowID: UUID?
}

#Preview {
  MainWindowRootView(
    nav3: Nav3(),
    chatOpenPreloader: Nav3ChatOpenPreloadBridge(),
    keyMonitor: KeyMonitor()
  )
    .environment(dependencies: AppDependencies())
}
