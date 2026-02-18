import InlineKit
import InlineUI
import Logger
import SwiftUI

struct ExperimentalRootView: View {
  private enum RootTab: Hashable {
    case chats
    case archived
  }

  @State private var nav = ExperimentalNavigationModel()
  @StateObject private var onboardingNavigation = OnboardingNavigation()
  @StateObject private var api = ApiClient()
  @StateObject private var userData = UserData()
  @StateObject private var mainViewRouter = MainViewRouter()
  @StateObject private var fileUploadViewModel = FileUploadViewModel()
  @StateObject private var tabsManager = TabsManager()
  @State private var rootTab: RootTab = .chats

  @Environment(Router.self) private var router
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentStateObject private var data: DataManager
  @EnvironmentStateObject private var home: HomeViewModel
  @EnvironmentStateObject private var compactSpaceList: CompactSpaceList
  @AppStorage(ExperimentalHomePreferenceKeys.chatScope) private var homeChatScopeRaw: String = ExperimentalHomeChatScope.all.rawValue
  @AppStorage(ExperimentalHomePreferenceKeys.chatItemRenderMode) private var chatItemRenderModeRaw: String = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue

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
        EmptyView()
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
    // Experimental UI pushes destinations above the TabView, so explicit tab bar hiding is unnecessary.
    .environment(\.inlineHideTabBar, false)
    .toastView()
  }

  private var mainTabs: some View {
    @Bindable var bindableRouter = router
    @Bindable var bindableNav = nav

    // Place the TabView at the root of a single NavigationStack so pushed destinations (ChatView, etc.)
    // render above it. This keeps the tab bar "home-only" without requiring per-screen hiding.
    return NavigationStack(path: $bindableRouter[bindableRouter.selectedTab]) {
      TabView(selection: $rootTab) {
        chatsRoot(nav: bindableNav, root: .archived)
          .tabItem {
            Label("Archived", systemImage: "archivebox.fill")
          }
          .tag(RootTab.archived)

        chatsRoot(nav: bindableNav, root: .chats)
          .tabItem {
            Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
          }
          .tag(RootTab.chats)
      }
      .background(Color(.systemBackground))
      .navigationBarTitleDisplayMode(.inline)
      .navigationTitle("")
      // Put the toolbar on the TabView root. Toolbars declared inside TabView pages can fail to
      // render reliably; attaching here keeps the top bar consistent.
      .toolbar {
        ToolbarItem(placement: .principal) {
          activeSpacePicker(selectedSpaceId: $bindableNav.activeSpaceId)
        }

        if #available(iOS 26.0, *) {
          ToolbarItem(placement: .topBarTrailing) {
            createThreadButton(activeSpaceId: bindableNav.activeSpaceId)
          }
          ToolbarSpacer(.fixed, placement: .topBarTrailing)
          ToolbarItem(placement: .topBarTrailing) {
            trailingButtonGroup
          }
        } else {
          ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 10) {
              createThreadButton(activeSpaceId: bindableNav.activeSpaceId)
              trailingButtonGroup
            }
          }
        }
      }
      // Match the app's translucent styling for the system tab bar.
      .toolbarBackground(.visible, for: .tabBar)
      .toolbarBackground(.thinMaterial, for: .tabBar)
      .navigationDestination(for: Destination.self) { destination in
        ExperimentalDestinationView(nav: bindableNav, destination: destination)
      }
    }
    // Prevent child views (e.g. ChatView) from "leaking" a dark toolbar color scheme back to the root.
    .toolbarColorScheme(colorScheme, for: .navigationBar)
    // Also reset any leaked toolbar background visibility state.
    .toolbarBackground(.visible, for: .navigationBar)
    .sheet(item: $bindableRouter.presentedSheet) { sheet in
      ExperimentalSheetView(sheet: sheet)
    }
    .onAppear {
      // Experimental UI only supports `.chats` and `.archived` as root tabs; normalize anything else.
      let desiredTab: AppTab = (bindableRouter.selectedTab == .archived) ? .archived : .chats
      if bindableRouter.selectedTab != desiredTab {
        bindableRouter.selectedTab = desiredTab
      }
      rootTab = (desiredTab == .archived) ? .archived : .chats
    }
    .onChange(of: bindableRouter.selectedTab) { _, newValue in
      let desiredRootTab: RootTab = (newValue == .archived) ? .archived : .chats
      if rootTab != desiredRootTab {
        rootTab = desiredRootTab
      }
    }
    .onChange(of: rootTab) { _, newValue in
      switch newValue {
      case .chats:
        if bindableRouter.selectedTab != .chats {
          bindableRouter.selectedTab = .chats
        }
      case .archived:
        if bindableRouter.selectedTab != .archived {
          bindableRouter.selectedTab = .archived
        }
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

  private func presentMembers() {
    guard let spaceId = nav.activeSpaceId else { return }
    router.presentSheet(.members(spaceId: spaceId))
  }

  // MARK: - Toolbar

  private var homeChatScope: ExperimentalHomeChatScope {
    ExperimentalHomeChatScope(rawValue: homeChatScopeRaw) ?? .all
  }

  private var homeChatScopeBinding: Binding<ExperimentalHomeChatScope> {
    Binding(
      get: { homeChatScope },
      set: { homeChatScopeRaw = $0.rawValue }
    )
  }

  private var chatItemRenderMode: ExperimentalHomeChatItemRenderMode {
    ExperimentalHomeChatItemRenderMode(rawValue: chatItemRenderModeRaw) ?? .twoLineLastMessage
  }

  private var chatItemRenderModeBinding: Binding<ExperimentalHomeChatItemRenderMode> {
    Binding(
      get: { chatItemRenderMode },
      set: { chatItemRenderModeRaw = $0.rawValue }
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
      .contentShape(Capsule())
      // Ensure the toolbar gives the label enough width to show the active space name.
      .frame(minWidth: 140, idealWidth: 180, maxWidth: 240, alignment: .leading)
  }

  @ViewBuilder
  private func createThreadButton(
    activeSpaceId: Int64?
  ) -> some View {
    Button {
      if let spaceId = activeSpaceId {
        router.push(.createThread(spaceId: spaceId), for: router.selectedTab)
      } else {
        router.push(.createSpaceChat, for: router.selectedTab)
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 36, height: 36)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("New Chat")
  }

  private var trailingButtonGroup: some View {
    HStack(spacing: 0) {
      NotificationSettingsButton()
        .frame(width: 36, height: 36)

      Divider()
        .opacity(0.35)
        .padding(.vertical, 8)

      Menu {
        if nav.activeSpaceId == nil {
          Picker("View", selection: homeChatScopeBinding) {
            ForEach(ExperimentalHomeChatScope.allCases) { scope in
              Label(scope.title, systemImage: scope.systemImage)
                .tag(scope)
            }
          }
        }

        Picker("Chat Items", selection: chatItemRenderModeBinding) {
          ForEach(ExperimentalHomeChatItemRenderMode.allCases) { mode in
            Label(mode.title, systemImage: mode.systemImage)
              .tag(mode)
          }
        }

        Button {
          presentMembers()
        } label: {
          Label("Members", systemImage: "person.2")
        }
        .disabled(nav.activeSpaceId == nil)

        Button {
          router.presentSheet(.settings)
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
      } label: {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 36, height: 36)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("More")
    }
  }
}
