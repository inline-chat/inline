import InlineKit
import InlineUI
import Logger
import SwiftUI

struct ExperimentalRootView: View {
  private enum RootTab: Hashable {
    case chats
    case search
    case archived

    init(appTab: AppTab) {
      switch appTab {
        case .archived:
          self = .archived
        case .search:
          self = .search
        case .chats, .spaces:
          self = .chats
      }
    }

    var appTab: AppTab {
      switch self {
        case .chats:
          .chats
        case .search:
          .search
        case .archived:
          .archived
      }
    }
  }

  @State private var nav = ExperimentalNavigationModel()
  @StateObject private var onboardingNavigation = OnboardingNavigation()
  @StateObject private var api = ApiClient()
  @StateObject private var userData = UserData()
  @StateObject private var mainViewRouter = MainViewRouter()
  @StateObject private var fileUploadViewModel = FileUploadViewModel()
  @StateObject private var tabsManager = TabsManager()
  @State private var rootTab: RootTab = .chats
  @State private var lastNonSearchRootTab: RootTab = .chats
  @State private var searchQuery = ""
  @State private var isSearchPresented = false
  @State private var isCreatingThread = false

  @Environment(Router.self) private var router
  @Environment(\.auth) private var auth
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentStateObject private var data: DataManager
  @EnvironmentStateObject private var home: HomeViewModel
  @EnvironmentStateObject private var compactSpaceList: CompactSpaceList

  init() {
    _data = EnvironmentStateObject { env in
      DataManager(database: env.appDatabase)
    }

    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }

    _compactSpaceList = EnvironmentStateObject { env in
      CompactSpaceList(db: env.appDatabase)
    }
  }

  var body: some View {
    Group {
      switch mainViewRouter.route {
        case .main:
          mainTabs
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
    .environmentObject(data)
    .environmentObject(mainViewRouter)
    .environmentObject(home)
    .environmentObject(fileUploadViewModel)
    .environmentObject(tabsManager)
    .environmentObject(compactSpaceList)
    // Experimental UI keeps navigation inside per-tab stacks; each stack owns tab bar visibility.
    .environment(\.inlineHideTabBar, false)
    .toastView()
    .onReceive(NotificationCenter.default.publisher(for: .localDataCleared)) { _ in
      nav.resetHomeDataState()
      Task {
        await refetchCoreDataAfterLocalDataCleared()
      }
    }
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

  private var mainTabs: some View {
    @Bindable var bindableRouter = router
    @Bindable var bindableNav = nav

    return TabView(selection: $rootTab) {
      Tab("Archived", systemImage: "archivebox.fill", value: .archived) {
        rootNavigationStack(
          nav: bindableNav,
          appTab: .archived,
          rootDestination: .archived
        )
      }

      Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .chats) {
        rootNavigationStack(
          nav: bindableNav,
          appTab: .chats,
          rootDestination: .chats
        )
      }

      Tab(value: .search, role: .search) {
        searchNavigationStack(nav: bindableNav)
      }
    }
    .background(Color(.systemBackground))
    .experimentalRootSearchable(text: $searchQuery, isPresented: $isSearchPresented)
    .sheet(item: $bindableRouter.presentedSheet) { sheet in
      ExperimentalSheetView(sheet: sheet)
    }
    .onAppear {
      // Experimental UI only supports `.chats`, `.archived`, and `.search` as root tabs.
      let desiredTab = RootTab(appTab: bindableRouter.selectedTab).appTab
      if bindableRouter.selectedTab != desiredTab {
        bindableRouter.selectedTab = desiredTab
      }
      rootTab = RootTab(appTab: desiredTab)
      if rootTab != .search {
        lastNonSearchRootTab = rootTab
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
    }
    .onChange(of: rootTab) { oldValue, newValue in
      let desiredTab = newValue.appTab
      if bindableRouter.selectedTab != desiredTab {
        bindableRouter.selectedTab = desiredTab
      }

      if newValue == .search {
        if oldValue != .search {
          lastNonSearchRootTab = oldValue
        }
        if !usesNativeSearchTabActivation {
          activateSearch()
        }
      } else {
        lastNonSearchRootTab = newValue
        if !usesNativeSearchTabActivation, isSearchPresented {
          isSearchPresented = false
        }
      }
    }
    .onChange(of: isSearchPresented) { _, newValue in
      guard !newValue else { return }
      guard !usesNativeSearchTabActivation else { return }
      guard rootTab == .search else { return }

      searchQuery = ""

      if rootTab != lastNonSearchRootTab {
        rootTab = lastNonSearchRootTab
      }
    }
  }

  private func chatsRoot(
    nav: ExperimentalNavigationModel,
    root: Destination
  ) -> some View {
    @Bindable var bindableNav = nav

    return ExperimentalDestinationView(nav: bindableNav, destination: root)
  }

  private func rootNavigationStack(
    nav: ExperimentalNavigationModel,
    appTab: AppTab,
    rootDestination: Destination
  ) -> some View {
    @Bindable var bindableRouter = router
    @Bindable var bindableNav = nav

    return NavigationStack(path: $bindableRouter[appTab]) {
      chatsRoot(nav: bindableNav, root: rootDestination)
        .background(Color(.systemBackground))
        .experimentalRootTitleDisplayMode()
        .navigationTitle("")
        .toolbar {
          experimentalToolbarContent(activeSpaceId: bindableNav.activeSpaceId)
        }
        .navigationDestination(for: Destination.self) { destination in
          ExperimentalDestinationView(nav: bindableNav, destination: destination)
        }
    }
    .toolbar(
      bindableRouter[appTab].isEmpty ? Visibility.visible : Visibility.hidden,
      for: .tabBar
    )
    // Prevent child views (e.g. ChatView) from "leaking" a dark toolbar color scheme back to the root.
    .toolbarColorScheme(colorScheme, for: .navigationBar)
    // Also reset any leaked toolbar background visibility state.
    .toolbarBackground(.visible, for: .navigationBar)
  }

  private func searchNavigationStack(
    nav: ExperimentalNavigationModel
  ) -> some View {
    @Bindable var bindableRouter = router
    @Bindable var bindableNav = nav

    return NavigationStack(path: $bindableRouter[.search]) {
      ExperimentalSearchView(query: searchQuery, activeSpaceId: bindableNav.activeSpaceId)
        .background(Color(.systemBackground))
        .experimentalRootTitleDisplayMode()
        .navigationTitle("")
        .navigationDestination(for: Destination.self) { destination in
          ExperimentalDestinationView(nav: bindableNav, destination: destination)
        }
    }
    .toolbar(
      bindableRouter[.search].isEmpty ? Visibility.visible : Visibility.hidden,
      for: .tabBar
    )
    .toolbarColorScheme(colorScheme, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
  }

  private var usesNativeSearchTabActivation: Bool {
    if #available(iOS 26.0, *) {
      true
    } else {
      false
    }
  }

  @ViewBuilder
  private func activeSpacePicker(
    selectedSpaceId: Binding<Int64?>
  ) -> some View {
    let picker = SpacePickerMenu(
      selectedSpaceId: selectedSpaceId,
      onSelectHome: {
        selectedSpaceId.wrappedValue = nil
        router.popToRoot(for: router.selectedTab)
      },
      onSelectSpace: { space in
        if selectedSpaceId.wrappedValue != space.id {
          selectedSpaceId.wrappedValue = space.id
        }
        router.popToRoot(for: router.selectedTab)
      },
      onCreateSpace: {
        router.push(.createSpace, for: router.selectedTab)
      }
    )

    picker
  }

  @ViewBuilder
  private func createThreadButton(
    activeSpaceId: Int64?
  ) -> some View {
    Button {
      createThreadInstantly(spaceId: activeSpaceId)
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: 36, height: 36)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(isCreatingThread)
    .accessibilityLabel("New Chat")
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
        let result = try await realtimeV2.send(
          .createChat(
            title: "",
            emoji: nil,
            isPublic: false,
            spaceId: spaceId,
            participants: [currentUserId]
          )
        )

        await MainActor.run {
          isCreatingThread = false

          if case let .createChat(response) = result {
            router.push(.chat(peer: .thread(id: response.chat.id)), for: router.selectedTab)
          } else {
            ToastManager.shared.showToast(
              "Failed to create thread.",
              type: .error,
              systemImage: "exclamationmark.triangle"
            )
          }
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

  private func activateSearch() {
    Task { @MainActor in
      await Task.yield()
      guard rootTab == .search else { return }
      isSearchPresented = true
    }
  }

  @ToolbarContentBuilder
  private func experimentalToolbarContent(activeSpaceId: Int64?) -> some ToolbarContent {
    if #available(iOS 26.0, *) {
      ToolbarItem(placement: .principal) {
        activeSpacePicker(selectedSpaceId: $nav.activeSpaceId)
      }
      .sharedBackgroundVisibility(.hidden)

      ToolbarItem(placement: .topBarTrailing) {
        notificationsButton
      }
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
      ToolbarItem(placement: .topBarTrailing) {
        settingsButton
      }
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
      ToolbarItem(placement: .topBarTrailing) {
        createThreadButton(activeSpaceId: activeSpaceId)
      }
    } else {
      ToolbarItem(placement: .topBarLeading) {
        activeSpacePicker(selectedSpaceId: $nav.activeSpaceId)
      }

      ToolbarItem(placement: .topBarTrailing) {
        HStack(spacing: 8) {
          settingsButton
          createThreadButton(activeSpaceId: activeSpaceId)
          notificationsButton
        }
      }
    }
  }

  private var notificationsButton: some View {
    NotificationSettingsButton(
      iconColor: .primary,
      iconFont: .system(size: 14, weight: .semibold)
    )
    .frame(width: 36, height: 36)
  }

  private var settingsButton: some View {
    Button {
      router.presentSheet(.settings)
    } label: {
      Image(systemName: "gearshape")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Settings")
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

private extension View {
  @ViewBuilder
  func experimentalRootTitleDisplayMode() -> some View {
    if #available(iOS 26.0, *) {
      toolbarTitleDisplayMode(.inlineLarge)
    } else {
      navigationBarTitleDisplayMode(.inline)
    }
  }

  @ViewBuilder
  func experimentalRootSearchable(
    text: Binding<String>,
    isPresented: Binding<Bool>
  ) -> some View {
    if #available(iOS 26.0, *) {
      searchable(text: text, prompt: "Find")
        .tabViewSearchActivation(.searchTabSelection)
    } else {
      searchable(text: text, isPresented: isPresented, prompt: "Find")
    }
  }
}
