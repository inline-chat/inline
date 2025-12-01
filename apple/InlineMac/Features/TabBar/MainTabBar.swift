import AppKit
import Combine
import InlineKit

private final class TabBarContainerView: NSView {
  // Allow window dragging when clicking outside tab controls.
  override var mouseDownCanMoveWindow: Bool { true }
}

private final class ShrinkingFlowLayout: NSCollectionViewFlowLayout {
  override func shouldInvalidateLayout(forBoundsChange _: NSRect) -> Bool {
    true
  }
}

private final class TabBarCollectionView: NSCollectionView {
  override var mouseDownCanMoveWindow: Bool { false }

  // Let empty background clicks pass through so the window can be dragged.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    return hit === self ? nil : hit
  }
}

struct TabModel: Hashable {
  let icon: String
  let title: String
}

class MainTabBar: NSViewController {
  private let tabHeight: CGFloat = Theme.tabBarItemHeight
  private let tabWidth: CGFloat = 120
  private let homeTabWidth: CGFloat = 50
  private let baseTabSpacing: CGFloat = Theme.tabBarItemInset
  private let iconSize: CGFloat = 22
  private var currentScale: CGFloat = 1

  private var topGap: CGFloat {
    Theme.tabBarHeight - tabHeight
  }

  private var collectionView: NSCollectionView!
  private var pinnedStack: NSStackView!
  private weak var spacesButton: TabSurfaceButton?

  private var dependencies: AppDependencies
  private var nav2: Nav2 { dependencies.nav2! }
  private var homeViewModel: HomeViewModel
  private var spaces: [HomeSpaceItem] = []
  private var spacesCancellable: AnyCancellable?

  private var lastObservedTabs: [TabId] = []
  private var lastObservedActiveIndex: Int = 0

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    homeViewModel = HomeViewModel(db: dependencies.database)
    super.init(nibName: nil, bundle: nil)
    setupObservers()
    observeSpaces()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let containerView = TabBarContainerView()
    containerView.wantsLayer = true

    let layout = ShrinkingFlowLayout()
    layout.scrollDirection = .horizontal
    layout.minimumInteritemSpacing = baseTabSpacing // Matches the inset for hovered
    layout.sectionInset = NSEdgeInsets(top: topGap, left: 0, bottom: 0, right: 40)

    collectionView = TabBarCollectionView()
    collectionView.collectionViewLayout = layout
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.isSelectable = true
    collectionView.allowsEmptySelection = true
    collectionView.backgroundColors = [.clear]
    collectionView.register(
      TabCollectionViewItem.self,
      forItemWithIdentifier: NSUserInterfaceItemIdentifier("TabItem")
    )
    collectionView.translatesAutoresizingMaskIntoConstraints = false

    pinnedStack = NSStackView()
    pinnedStack.orientation = .horizontal
    pinnedStack.spacing = 6
    pinnedStack.alignment = .centerY
    pinnedStack.translatesAutoresizingMaskIntoConstraints = false

    let spacesButton = TabSurfaceButton(
      symbolName: "square.grid.2x2.fill",
      pointSize: 17,
      weight: .medium,
      tintColor: .tertiaryLabelColor
    )
    spacesButton.toolTip = "Spaces"
    spacesButton.onTap = { [weak self] in
      self?.openSpacesMenu(from: spacesButton)
    }
    self.spacesButton = spacesButton

    pinnedStack.addArrangedSubview(spacesButton)

    containerView.addSubview(collectionView)
    containerView.addSubview(pinnedStack)

    NSLayoutConstraint.activate([
      pinnedStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
      pinnedStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: topGap),
      pinnedStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

      collectionView.topAnchor.constraint(equalTo: containerView.topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: pinnedStack.trailingAnchor, constant: 4),
      collectionView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: 0),
      collectionView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
    ])

    view = containerView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    collectionView.reloadData()
    selectActiveTab()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    updateLayoutForCurrentWidth()
    collectionView.collectionViewLayout?.invalidateLayout()
  }

  private func updateLayoutForCurrentWidth() {
    guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
    let availableWidth = max(
      collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right,
      1
    )
    let scale = layoutScale(forAvailableWidth: availableWidth)
    currentScale = scale
    layout.minimumInteritemSpacing = baseTabSpacing * scale

    // Force relayout so the delegate size calculation re-runs after space changes.
    collectionView.collectionViewLayout?.invalidateLayout()
    collectionView.collectionViewLayout?.prepare()
  }

  private func setupObservers() {
    withObservationTracking { [weak self] in
      guard let self else { return }
      lastObservedTabs = nav2.tabs
      lastObservedActiveIndex = nav2.activeTabIndex
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }

        let previousTabs = lastObservedTabs
        let previousActive = lastObservedActiveIndex
        let currentTabs = nav2.tabs
        let currentActive = nav2.activeTabIndex

        if previousTabs != currentTabs {
          collectionView?.reloadData()
        } else {
          var indexPaths = Set<IndexPath>()

          if previousActive < currentTabs.count {
            indexPaths.insert(IndexPath(item: previousActive, section: 0))
          }
          if currentActive < currentTabs.count {
            indexPaths.insert(IndexPath(item: currentActive, section: 0))
          }

          if !indexPaths.isEmpty {
            collectionView?.reloadItems(at: indexPaths)
          }
        }

        selectActiveTab()
        setupObservers()
      }
    }
  }

  private func selectActiveTab() {
    guard let collectionView else { return }

    let activeIndex = nav2.activeTabIndex

    collectionView.deselectAll(nil)

    if activeIndex < nav2.tabs.count {
      let indexPath = IndexPath(item: activeIndex, section: 0)
      collectionView.selectItems(at: [indexPath], scrollPosition: [])
    }
  }

  private func tabModel(for tabId: TabId) -> TabModel {
    switch tabId {
      case .home:
        TabModel(icon: "house", title: "Home")
      case let .space(id, name):
        TabModel(icon: "number", title: name)
    }
  }

  private func space(for tabId: TabId) -> Space? {
    switch tabId {
      case let .space(id, _):
        if let local = spaces.first(where: { $0.space.id == id })?.space {
          return local
        }
        return ObjectCache.shared.getSpace(id: id)
      case .home:
        return nil
    }
  }

  private func spaceAvatar(for space: Space, size: CGFloat) -> NSImage? {
    let initials = space.displayName
      .split(separator: " ")
      .compactMap(\.first)
      .prefix(2)
      .map(String.init)
      .joined()
      .uppercased()

    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let path = NSBezierPath(ovalIn: rect)
    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
    path.fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: size * 0.45, weight: .semibold),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraph,
    ]

    let string = initials.isEmpty ? "·" : initials
    let attr = NSAttributedString(string: string, attributes: attributes)
    let strSize = attr.size()
    let strRect = NSRect(
      x: (size - strSize.width) / 2,
      y: (size - strSize.height) / 2,
      width: strSize.width,
      height: strSize.height
    )
    attr.draw(in: strRect)

    image.unlockFocus()
    return image
  }

  private func isTabClosable(at index: Int) -> Bool {
    guard index < nav2.tabs.count else { return false }
    return nav2.tabs[index] != .home
  }

  private func observeSpaces() {
    spacesCancellable = homeViewModel.$spaces
      .receive(on: RunLoop.main)
      .sink { [weak self] items in
        self?.spaces = items
      }
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
        item.image = makeInitialsImage(text: spaceItem.space.displayName)
        menu.addItem(item)
      }
    }

    // Refresh spaces from backend in the background
    Task.detached { [weak self] in
      guard let deps = self?.dependencies else { return }
      _ = try? await deps.data.getSpaces()
    }

    // Show the menu just below the button so it doesn't cover it
    let location = NSPoint(x: 0, y: -10)
    menu.popUp(positioning: nil, at: location, in: anchor)
  }

  @objc
  private func didSelectSpace(_ sender: NSMenuItem) {
    guard let space = sender.representedObject as? Space else { return }
    nav2.openSpace(space)
    collectionView.reloadData()
  }

  private func makeInitialsImage(text: String, diameter: CGFloat = 20) -> NSImage? {
    let image = NSImage(size: NSSize(width: diameter, height: diameter))
    image.lockFocus()

    let circlePath = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter))
    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
    circlePath.fill()

    let initials = text
      .split(separator: " ")
      .compactMap(\.first)
      .prefix(2)
      .map(String.init)
      .joined()
      .uppercased()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraph,
    ]

    let attributed = NSAttributedString(string: initials.isEmpty ? "·" : initials, attributes: attributes)
    let size = attributed.size()
    let rect = NSRect(
      x: (diameter - size.width) / 2,
      y: (diameter - size.height) / 2,
      width: size.width,
      height: size.height
    )
    attributed.draw(in: rect)

    image.unlockFocus()
    return image
  }
}

extension MainTabBar: NSCollectionViewDataSource {
  func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
    nav2.tabs.count
  }

  func collectionView(
    _ collectionView: NSCollectionView,
    itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    let item = collectionView.makeItem(
      withIdentifier: NSUserInterfaceItemIdentifier("TabItem"),
      for: indexPath
    ) as! TabCollectionViewItem

    let tabId = nav2.tabs[indexPath.item]
    let tab = tabModel(for: tabId)
    let selected = nav2.activeTabIndex == indexPath.item
    let closable = isTabClosable(at: indexPath.item)
    let iconImage: NSImage? = {
      switch tabId {
        case .home:
          return nil
        case let .space(id, _):
          if let space = space(for: tabId) {
            return spaceAvatar(for: space, size: iconSize)
          } else {
            // Start observing for updates
            ObjectCache.shared.observeSpace(id: id)
            return nil
          }
      }
    }()

    item.configure(
      with: tab,
      iconSize: iconSize,
      scale: currentScale,
      selected: selected,
      closable: closable,
      iconImage: iconImage
    )
    item.onClose = { [weak self] in
      self?.nav2.removeTab(at: indexPath.item)
    }

    return item
  }
}

extension MainTabBar: NSCollectionViewDelegate {
  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard let indexPath = indexPaths.first else { return }
    nav2.setActiveTab(index: indexPath.item)
  }
}

extension MainTabBar: NSCollectionViewDelegateFlowLayout {
  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> NSSize {
    guard indexPath.item < nav2.tabs.count else { return NSSize(width: 0, height: tabHeight) }
    let tabId = nav2.tabs[indexPath.item]
    let baseWidth = tabId == .home ? homeTabWidth : tabWidth

    guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else {
      return NSSize(width: baseWidth, height: tabHeight)
    }

    // Available width within the collection view’s content area.
    let availableWidth = max(
      collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right,
      1
    )

    let scale = layoutScale(forAvailableWidth: availableWidth)
    currentScale = scale
    let scaledWidth = floor(baseWidth * scale)

    return NSSize(width: scaledWidth, height: tabHeight)
  }

  private func layoutScale(forAvailableWidth availableWidth: CGFloat) -> CGFloat {
    let tabCount = CGFloat(nav2.tabs.count)
    guard tabCount > 0 else { return 1 }

    let baseSpacingTotal = baseTabSpacing * max(0, tabCount - 1)
    let baseWidthTotal = CGFloat(nav2.tabs.reduce(0) { sum, tab in
      sum + (tab == .home ? homeTabWidth : tabWidth)
    })

    let denominator = baseWidthTotal + baseSpacingTotal
    guard denominator > 0 else { return 1 }

    return min(1, availableWidth / denominator)
  }
}
