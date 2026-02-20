import AppKit
import Combine
import InlineKit
import InlineMacUI
import Observation

@MainActor
final class MainTabStripController: NSViewController {
  private enum TabStripIdentifier {
    static let home = "home"

    static func space(_ id: Int64) -> String {
      "space:\(id)"
    }

    static func spaceID(from identifier: String) -> Int64? {
      guard identifier.hasPrefix("space:") else { return nil }
      let raw = String(identifier.dropFirst("space:".count))
      return Int64(raw)
    }
  }

  private let dependencies: AppDependencies
  private let homeViewModel: HomeViewModel
  private let iconSize: CGFloat = CollectionTabStripViewController.Layout.iconViewSize

  private var spaces: [HomeSpaceItem] = []
  private var spacesCancellable: AnyCancellable?
  private var quickSearchVisibilityObserver: NSObjectProtocol?
  private var isQuickSearchVisible = false

  private weak var tabStripController: CollectionTabStripViewController?
  private var pendingLeadingPadding: CGFloat = 12

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    homeViewModel = HomeViewModel(db: dependencies.database)
    super.init(nibName: nil, bundle: nil)
    observeSpaces()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let root = NSView()
    root.wantsLayer = true

    let tabStrip = CollectionTabStripViewController()
    tabStrip.onSelect = { [weak self] identifier in
      self?.selectTab(with: identifier)
    }
    tabStrip.onClose = { [weak self] identifier in
      self?.closeTab(with: identifier)
    }
    tabStrip.onLeadingAccessoryTap = { [weak self] anchor in
      self?.openSpacesMenu(from: anchor)
    }
    tabStrip.iconProvider = { [weak self] identifier in
      self?.icon(for: identifier)
    }

    addChild(tabStrip)
    root.addSubview(tabStrip.view)
    tabStrip.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      tabStrip.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      tabStrip.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      tabStrip.view.topAnchor.constraint(equalTo: root.topAnchor),
      tabStrip.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])

    view = root
    tabStripController = tabStrip
    tabStrip.updateLeadingPadding(pendingLeadingPadding, animated: false)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observeNavTabs()
    syncTabStrip()
    setupQuickSearchObserver()
  }

  deinit {
    if let quickSearchVisibilityObserver {
      NotificationCenter.default.removeObserver(quickSearchVisibilityObserver)
    }
  }

  private func observeNavTabs() {
    guard let nav2 = dependencies.nav2 else { return }

    withObservationTracking { [weak self] in
      guard let self else { return }
      _ = nav2.tabs
      _ = nav2.activeTabIndex
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.syncTabStrip()
        self?.observeNavTabs()
      }
    }
  }

  private func setupQuickSearchObserver() {
    guard quickSearchVisibilityObserver == nil else { return }

    quickSearchVisibilityObserver = NotificationCenter.default.addObserver(
      forName: .quickSearchVisibilityChanged,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
            let isVisible = notification.userInfo?["isVisible"] as? Bool,
            isQuickSearchVisible != isVisible
      else { return }

      isQuickSearchVisible = isVisible
      syncTabStrip()
    }
  }

  private func observeSpaces() {
    spacesCancellable = homeViewModel.$spaces
      .receive(on: RunLoop.main)
      .sink { [weak self] items in
        self?.spaces = items
        self?.syncTabStrip()
      }
  }

  private func syncTabStrip() {
    guard let nav2,
          let tabStripController
    else { return }

    let items = nav2.tabs.map(makeTabStripItem(for:))
    let selectedID = isQuickSearchVisible ? nil : identifier(for: nav2.activeTab)

    tabStripController.update(
      items: items,
      selectedItemID: selectedID,
      selectionHidden: isQuickSearchVisible
    )
  }

  func updateLeadingPadding(
    _ padding: CGFloat,
    animated: Bool = false,
    duration: TimeInterval = 0.2
  ) {
    pendingLeadingPadding = padding
    tabStripController?.updateLeadingPadding(padding, animated: animated, duration: duration)
  }

  private func makeTabStripItem(for tab: TabId) -> TabStripItem {
    switch tab {
      case .home:
        return TabStripItem(
          id: TabStripIdentifier.home,
          title: "Home",
          systemIconName: "house",
          style: .home,
          isClosable: false
        )
      case let .space(id, name):
        return TabStripItem(
          id: TabStripIdentifier.space(id),
          title: name,
          style: .standard,
          isClosable: true
        )
    }
  }

  private func identifier(for tab: TabId) -> String {
    switch tab {
      case .home:
        TabStripIdentifier.home
      case let .space(id, _):
        TabStripIdentifier.space(id)
    }
  }

  private var nav2: Nav2? {
    dependencies.nav2
  }

  private func selectTab(with identifier: String) {
    guard let nav2,
          let index = nav2.tabs.firstIndex(where: { self.identifier(for: $0) == identifier })
    else { return }

    nav2.setActiveTab(index: index)
  }

  private func closeTab(with identifier: String) {
    guard let nav2,
          let index = nav2.tabs.firstIndex(where: { self.identifier(for: $0) == identifier })
    else { return }

    nav2.removeTab(at: index)
  }

  private func icon(for identifier: String) -> NSImage? {
    guard let spaceID = TabStripIdentifier.spaceID(from: identifier) else { return nil }
    if let space = spaces.first(where: { $0.space.id == spaceID })?.space ?? ObjectCache.shared.getSpace(id: spaceID) {
      return avatarImage(for: space)
    }

    ObjectCache.shared.observeSpace(id: spaceID)
    let fallbackTitle = tabTitle(for: spaceID) ?? "·"
    let fallbackSpace = Space(id: spaceID, name: fallbackTitle, date: Date())
    return avatarImage(for: fallbackSpace)
  }

  private func tabTitle(for spaceID: Int64) -> String? {
    guard let nav2 else { return nil }
    for tab in nav2.tabs {
      if case let .space(id, name) = tab, id == spaceID {
        return name
      }
    }
    return nil
  }

  private func openSpacesMenu(from anchor: NSView) {
    let menu = NSMenu()

    if spaces.isEmpty {
      let empty = NSMenuItem(title: "No spaces yet", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    } else {
      for spaceItem in spaces {
        let item = NSMenuItem(
          title: spaceItem.space.displayName,
          action: #selector(didSelectSpace(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.representedObject = spaceItem.space
        item.image = avatarImage(for: spaceItem.space, size: 20)
        menu.addItem(item)
      }
    }

    Task { [weak self] in
      guard let dependencies = self?.dependencies else { return }
      _ = try? await dependencies.data.getSpaces()
    }

    let location = NSPoint(x: 0, y: -10)
    menu.popUp(positioning: nil, at: location, in: anchor)
  }

  @objc private func didSelectSpace(_ sender: NSMenuItem) {
    guard let nav2,
          let space = sender.representedObject as? Space
    else { return }

    nav2.openSpace(space)
    syncTabStrip()
  }

  private func avatarImage(for space: Space, size: CGFloat? = nil) -> NSImage {
    let image = SpaceAvatarView.image(for: space, size: size ?? iconSize)
    image.isTemplate = false
    return image
  }
}
