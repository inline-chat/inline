import AppKit
import InlineKit
import InlineMacUI
import InlineUI
import SwiftUI

class MainSidebarHeaderView: NSView {
  private static let defaultHeight: CGFloat = MainSidebar.itemHeight

  private let dependencies: AppDependencies
  private var heightConstraint: NSLayoutConstraint?
  private var hostingView: NSHostingView<SidebarHeaderRootView>?

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    setupHosting()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupHosting() {
    let nav2 = dependencies.nav2 ?? Nav2()
    let rootView = SidebarHeaderRootView(
      nav2: nav2,
      database: dependencies.database,
      onHeightChange: { [weak self] height in
        guard let self else { return }
        let clamped = max(Self.defaultHeight, height)
        if heightConstraint?.constant != clamped {
          heightConstraint?.constant = clamped
          invalidateIntrinsicContentSize()
        }
      }
    )

    let hostingView = NSHostingView(rootView: rootView)
    hostingView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(hostingView)

    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    heightConstraint = heightAnchor.constraint(equalToConstant: Self.defaultHeight)
    heightConstraint?.isActive = true

    self.hostingView = hostingView
  }
}

private struct SidebarHeaderRootView: View {
  let nav2: Nav2
  @StateObject private var homeViewModel: HomeViewModel
  let onHeightChange: (CGFloat) -> Void

  @State private var isExpanded = false
  @State private var isQuickSearchVisible = false
  @State private var expandedTopItem: SpaceHeaderItem?
  @State private var expandedItemsSnapshot: [SpaceHeaderItem] = []

  init(nav2: Nav2, database: AppDatabase, onHeightChange: @escaping (CGFloat) -> Void) {
    self.nav2 = nav2
    _homeViewModel = StateObject(wrappedValue: HomeViewModel(db: database))
    self.onHeightChange = onHeightChange
  }

  var body: some View {
    @Bindable var nav2 = nav2
    let activeTab = nav2.activeTab
    let isNewThreadActive = nav2.currentRoute == .newChat && !isQuickSearchVisible
    let items = makeItems(activeTab: activeTab)

    VStack(spacing: MainSidebar.itemSpacing) {
      ForEach(items) { item in
        SidebarHeaderRow(
          item: item,
          isActive: item.matches(spaceId: activeTab.spaceId, isHome: activeTab == .home),
          showsToggle: shouldShowToggle(for: item, activeTab: activeTab),
          showsMenu: item.kind == .space && item.spaceId == activeTab.spaceId,
          isExpanded: isExpanded,
          onSelect: {
            select(item)
          },
          onToggle: {
            toggleExpansion(activeTab: activeTab)
          },
          onMenu: {
            if let spaceId = item.spaceId {
              nav2.navigate(to: .members(spaceId: spaceId))
            }
          },
          menuContent: {
            if let spaceId = item.spaceId {
              Button("Members") { nav2.navigate(to: .members(spaceId: spaceId)) }
              Button("Invite") { nav2.navigate(to: .inviteToSpace) }
              Button("Integrations") { nav2.navigate(to: .spaceIntegrations(spaceId: spaceId)) }
            }
          }
        )
      }
      SidebarQuickActionsSection(
        isSearchActive: isQuickSearchVisible,
        isNewThreadActive: isNewThreadActive,
        onSearch: {
          triggerQuickSearch()
        },
        onNewThread: {
          openNewThread()
        }
      )
    }
    .background(HeightReader(onHeightChange: onHeightChange))
    .onReceive(NotificationCenter.default.publisher(for: .quickSearchVisibilityChanged)) { notification in
      guard let isVisible = notification.userInfo?["isVisible"] as? Bool else { return }
      isQuickSearchVisible = isVisible
    }
  }

  private func shouldShowToggle(for item: SpaceHeaderItem, activeTab: TabId) -> Bool {
    if isExpanded {
      if let expandedTopItem {
        return item == expandedTopItem
      }
      return item.matches(spaceId: activeTab.spaceId, isHome: activeTab == .home)
    }
    return item.matches(spaceId: activeTab.spaceId, isHome: activeTab == .home)
  }

  private func makeItems(activeTab: TabId) -> [SpaceHeaderItem] {
    if isExpanded {
      if let expandedTopItem {
        return [expandedTopItem] + expandedItemsSnapshot
      }
      return makeExpandedSnapshot(activeTab: activeTab).combined
    }

    switch activeTab {
      case .home:
        return [.home]
      case let .space(id, name):
        let fallback = ObjectCache.shared.getSpace(id: id) ?? Space(id: id, name: name, date: Date())
        return [SpaceHeaderItem(space: fallback)]
    }
  }

  private func toggleExpansion(activeTab: TabId) {
    if isExpanded {
      isExpanded = false
      expandedTopItem = nil
      expandedItemsSnapshot = []
      return
    }

    let snapshot = makeExpandedSnapshot(activeTab: activeTab)
    expandedTopItem = snapshot.top
    expandedItemsSnapshot = snapshot.rest
    isExpanded = true
  }

  private func makeExpandedSnapshot(activeTab: TabId) -> (top: SpaceHeaderItem, rest: [SpaceHeaderItem], combined: [SpaceHeaderItem]) {
    let top = item(for: activeTab)
    var rest: [SpaceHeaderItem] = [.home]
    rest.append(contentsOf: homeViewModel.spaces.map { SpaceHeaderItem(space: $0.space) })
    if let index = rest.firstIndex(of: top) {
      rest.remove(at: index)
    }
    return (top: top, rest: rest, combined: [top] + rest)
  }

  private func item(for activeTab: TabId) -> SpaceHeaderItem {
    switch activeTab {
      case .home:
        return .home
      case let .space(id, name):
        let fallback = ObjectCache.shared.getSpace(id: id) ?? Space(id: id, name: name, date: Date())
        return SpaceHeaderItem(space: fallback)
    }
  }

  private func select(_ item: SpaceHeaderItem) {
    switch item.kind {
      case .home:
        if let index = nav2.tabs.firstIndex(of: .home) {
          nav2.setActiveTab(index: index)
        }
      case .space:
        if let space = item.space {
          nav2.openSpace(space)
        }
    }
  }

  private func triggerQuickSearch() {
    NotificationCenter.default.post(name: .focusSearch, object: nil)
  }

  private func openNewThread() {
    nav2.navigate(to: .newChat)
  }
}

private struct SidebarQuickActionsSection: View {
  private static let dividerOpacity: CGFloat = 0.08
  private static let dividerVerticalPadding: CGFloat = 6

  let isSearchActive: Bool
  let isNewThreadActive: Bool
  let onSearch: () -> Void
  let onNewThread: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      topDivider
      SidebarActionRow(
        title: "Search",
        systemImage: "magnifyingglass",
        isActive: isSearchActive,
        onTap: onSearch
      )
      Spacer()
        .frame(height: MainSidebar.itemSpacing)
      SidebarActionRow(
        title: "New thread",
        systemImage: "square.and.pencil",
        isActive: isNewThreadActive,
        onTap: onNewThread
      )
      bottomDivider
    }
  }

  private var topDivider: some View {
    SidebarSeparator(
      opacity: Self.dividerOpacity,
      topPadding: Self.dividerVerticalPadding,
      bottomPadding: Self.dividerVerticalPadding
    )
  }

  private var bottomDivider: some View {
    SidebarSeparator(
      opacity: Self.dividerOpacity,
      topPadding: Self.dividerVerticalPadding,
      bottomPadding: 0
    )
  }
}

private struct SidebarSeparator: View {
  let opacity: CGFloat
  let topPadding: CGFloat
  let bottomPadding: CGFloat

  var body: some View {
    Rectangle()
      .fill(Color(nsColor: .labelColor).opacity(opacity))
      .frame(height: 1)
      .padding(.horizontal, MainSidebar.innerEdgeInsets)
      .padding(.top, topPadding)
      .padding(.bottom, bottomPadding)
  }
}

private struct SidebarActionRow: View {
  let title: String
  let systemImage: String
  let isActive: Bool
  let onTap: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: MainSidebar.iconTrailingPadding) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(textColor)
        .frame(width: MainSidebar.iconSize, height: MainSidebar.iconSize)

      Text(title)
        .font(Font(MainSidebar.font))
        .foregroundColor(textColor)
        .lineLimit(1)

      Spacer(minLength: 0)
    }
    .frame(height: MainSidebar.itemHeight)
    .padding(.horizontal, MainSidebar.innerEdgeInsets)
    .background(backgroundView)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onHover { hovering in
      isHovered = hovering
    }
    .onTapGesture {
      onTap()
    }
  }

  private var backgroundView: some View {
    Group {
      if isActive {
        Color(nsColor: Theme.windowContentBackgroundColor)
      } else if isHovered {
        Color.white.opacity(0.2)
      } else {
        Color.clear
      }
    }
  }

  private var textColor: Color {
    (isActive || isHovered)
      ? Color(nsColor: .labelColor)
      : Color(nsColor: .secondaryLabelColor)
  }
}

private struct SidebarHeaderRow<MenuContent: View>: View {
  let item: SpaceHeaderItem
  let isActive: Bool
  let showsToggle: Bool
  let showsMenu: Bool
  let isExpanded: Bool
  let onSelect: () -> Void
  let onToggle: () -> Void
  let onMenu: () -> Void
  @ViewBuilder let menuContent: () -> MenuContent

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: MainSidebar.iconTrailingPadding) {
      tappableContent

      if showsMenu && isHovered {
        Menu {
          menuContent()
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(textColor)
            .padding(4)
            .background(Circle().fill(Color.black.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focusable(false)
      }

      if showsToggle {
        Button(action: onToggle) {
          Image(systemName: "chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(textColor)
            .padding(4)
            .background(
              Circle().fill(Color.black.opacity(isHovered ? 0.08 : 0))
            )
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .buttonStyle(.plain)
        .focusable(false)
      }
    }
    .frame(height: MainSidebar.itemHeight)
    .padding(.horizontal, MainSidebar.innerEdgeInsets)
    .background(backgroundView)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onHover { hovering in
      isHovered = hovering
    }
    .onTapGesture {
      if showsToggle {
        onToggle()
      } else {
        onSelect()
      }
    }
  }

  private var tappableContent: some View {
    HStack(spacing: MainSidebar.iconTrailingPadding) {
      iconView
      Text(item.title)
        .font(Font(MainSidebar.font))
        .foregroundColor(textColor)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var iconView: some View {
    Group {
      switch item.kind {
        case .home:
          Image(systemName: "house.fill")
            .font(.system(size: Theme.sidebarTitleIconSize * 0.7, weight: .semibold))
            .foregroundColor(textColor)
            .frame(width: Theme.sidebarTitleIconSize, height: Theme.sidebarTitleIconSize)
        case .space:
          if let space = item.space {
            SpaceAvatar(space: space, size: Theme.sidebarTitleIconSize)
          }
      }
    }
  }

  private var backgroundView: some View {
    Group {
      if isExpanded && isActive {
        Color(nsColor: Theme.windowContentBackgroundColor)
      } else if isHovered && !(isActive && !isExpanded) {
        Color.white.opacity(0.2)
      } else {
        Color.clear
      }
    }
  }

  private var textColor: Color {
    (isExpanded && isActive) || (isHovered && !(isActive && !isExpanded))
      ? Color(nsColor: .labelColor)
      : Color(nsColor: .secondaryLabelColor)
  }
}

private struct SpaceHeaderItem: Identifiable, Hashable {
  enum Kind {
    case home
    case space
  }

  let kind: Kind
  let space: Space?

  var id: String {
    switch kind {
      case .home:
        "home"
      case .space:
        "space-\(space?.id ?? 0)"
    }
  }

  var title: String {
    switch kind {
      case .home:
        "Home"
      case .space:
        space?.displayName ?? "Untitled Space"
    }
  }

  var spaceId: Int64? { space?.id }

  static var home: SpaceHeaderItem {
    SpaceHeaderItem(kind: .home)
  }

  private init(kind: Kind, space: Space? = nil) {
    self.kind = kind
    self.space = space
  }

  init(space: Space) {
    kind = .space
    self.space = space
  }

  func matches(spaceId: Int64?, isHome: Bool) -> Bool {
    switch kind {
      case .home:
        return isHome
      case .space:
        return spaceId != nil && spaceId == self.spaceId
    }
  }
}

private struct HeightReader: View {
  let onHeightChange: (CGFloat) -> Void

  var body: some View {
    GeometryReader { proxy in
      Color.clear
        .preference(key: HeightPreferenceKey.self, value: proxy.size.height)
    }
    .onPreferenceChange(HeightPreferenceKey.self) { height in
      onHeightChange(height)
    }
  }
}

private enum HeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
