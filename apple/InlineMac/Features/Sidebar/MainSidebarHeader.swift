import AppKit
import InlineKit
import InlineMacUI
import InlineUI
import SwiftUI

class MainSidebarHeaderView: NSView {
  private static let defaultHeight: CGFloat = MainSidebar.itemHeight

  private let dependencies: AppDependencies
  private let spacePickerState: SpacePickerState
  private var heightConstraint: NSLayoutConstraint?
  private var hostingView: NSHostingView<SidebarHeaderRootView>?
  // MainSidebar hosts the overlay; header reports visibility for positioning.
  var onSpacePickerChange: ((Bool) -> Void)?

  init(dependencies: AppDependencies, spacePickerState: SpacePickerState) {
    self.dependencies = dependencies
    self.spacePickerState = spacePickerState
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
      spacePickerState: spacePickerState,
      onHeightChange: { [weak self] height in
        guard let self else { return }
        let clamped = max(Self.defaultHeight, height)
        if heightConstraint?.constant != clamped {
          heightConstraint?.constant = clamped
          invalidateIntrinsicContentSize()
        }
      },
      onSpacePickerChange: { [weak self] isVisible in
        self?.onSpacePickerChange?(isVisible)
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
  @ObservedObject var spacePickerState: SpacePickerState
  let onHeightChange: (CGFloat) -> Void
  let onSpacePickerChange: (Bool) -> Void

  init(
    nav2: Nav2,
    spacePickerState: SpacePickerState,
    onHeightChange: @escaping (CGFloat) -> Void,
    onSpacePickerChange: @escaping (Bool) -> Void
  ) {
    self.nav2 = nav2
    self.spacePickerState = spacePickerState
    self.onHeightChange = onHeightChange
    self.onSpacePickerChange = onSpacePickerChange
  }

  var body: some View {
    @Bindable var nav2 = nav2
    let activeTab = nav2.activeTab
    let item = item(for: activeTab)

    VStack(spacing: MainSidebar.itemSpacing) {
      SidebarHeaderRow(
        item: item,
        isActive: true,
        showsArrow: true,
        showsMenu: item.kind == .space && item.spaceId == activeTab.spaceId,
        isExpanded: spacePickerState.isVisible,
        onSelect: {
          spacePickerState.isVisible.toggle()
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
    .background(HeightReader(onHeightChange: onHeightChange))
    .onChange(of: nav2.activeTab) { _ in
      spacePickerState.isVisible = false
    }
    .onChange(of: spacePickerState.isVisible) { isVisible in
      onSpacePickerChange(isVisible)
    }
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

}

// Intentionally no anchor reporting: MainSidebar positions overlay under headerView.

private struct SidebarHeaderRow<MenuContent: View>: View {
  let item: SpaceHeaderItem
  let isActive: Bool
  let showsArrow: Bool
  let showsMenu: Bool
  let isExpanded: Bool
  let onSelect: () -> Void
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
    }
    .frame(height: MainSidebar.itemHeight)
    .padding(.horizontal, MainSidebar.innerEdgeInsets)
    .background(backgroundView)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onHover { hovering in
      isHovered = hovering
    }
  }

  private var tappableContent: some View {
    HStack(spacing: MainSidebar.iconTrailingPadding) {
      iconView
      Text(item.title)
        .font(Font(MainSidebar.font))
        .foregroundColor(textColor)
        .lineLimit(1)
      if showsArrow {
        Image(systemName: "chevron.down")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(textColor)
          .rotationEffect(.degrees(isExpanded ? 180 : 0))
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onTapGesture {
      onSelect()
    }
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

struct SpaceHeaderItem: Identifiable, Hashable {
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
