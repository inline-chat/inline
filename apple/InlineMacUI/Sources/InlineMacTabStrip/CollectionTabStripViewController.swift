import AppKit
import MacTheme

private final class TabStripContainerView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }
}

private final class TabStripFlowLayout: NSCollectionViewFlowLayout {
  override func shouldInvalidateLayout(forBoundsChange _: NSRect) -> Bool {
    true
  }
}

private final class TabStripCollectionView: NSCollectionView {
  override var mouseDownCanMoveWindow: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    return hit === self ? nil : hit
  }
}

public final class CollectionTabStripViewController: NSViewController {
  public enum Layout {
    public static let iconViewSize: CGFloat = 18
    public static let iconTopInset: CGFloat = 13

    public static var tabBarTopInset: CGFloat {
      Theme.tabBarHeight - Theme.tabBarItemHeight
    }

    public static var surfaceButtonHeight: CGFloat {
      Theme.tabBarItemHeight - Theme.tabBarItemInset
    }

    public static var surfaceButtonTopInset: CGFloat {
      tabBarTopInset
    }

    public static func iconCenterYOffset(viewHeight: CGFloat, viewTopInset: CGFloat) -> CGFloat {
      let iconCenterFromTop = iconTopInset + iconViewSize / 2
      let viewCenterFromTop = viewTopInset + viewHeight / 2
      return iconCenterFromTop - viewCenterFromTop
    }

    public static var tabItemIconCenterYOffset: CGFloat {
      iconCenterYOffset(viewHeight: Theme.tabBarItemHeight, viewTopInset: tabBarTopInset)
    }

    public static var surfaceButtonIconCenterYOffset: CGFloat {
      iconCenterYOffset(viewHeight: surfaceButtonHeight, viewTopInset: surfaceButtonTopInset)
    }
  }

  public var onSelect: ((String) -> Void)?
  public var onClose: ((String) -> Void)?
  public var onLeadingAccessoryTap: ((NSView) -> Void)?
  public var iconProvider: ((String) -> NSImage?)?

  private let tabHeight: CGFloat = Theme.tabBarItemHeight
  private let homeTabWidth: CGFloat = 36
  private let baseTabSpacing: CGFloat = Theme.tabBarItemInset
  private let iconSize: CGFloat = Layout.iconViewSize
  private let itemIdentifier = NSUserInterfaceItemIdentifier("TabStripItem")

  private var currentScale: CGFloat = 1
  private var items: [TabStripItem] = []
  private var selectedItemID: String?
  private var selectionHidden = false

  private var topGap: CGFloat {
    Theme.tabBarHeight - tabHeight
  }

  private var collectionView: NSCollectionView?
  private var pinnedStack: NSStackView?
  private var pinnedStackLeadingConstraint: NSLayoutConstraint?
  private weak var leadingButton: TabStripSurfaceButton?

  private let leadingAccessorySymbolName: String

  public init(leadingAccessorySymbolName: String = "square.grid.2x2.fill") {
    self.leadingAccessorySymbolName = leadingAccessorySymbolName
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public override func loadView() {
    let containerView = TabStripContainerView()
    containerView.wantsLayer = true

    let layout = TabStripFlowLayout()
    layout.scrollDirection = .horizontal
    layout.minimumInteritemSpacing = baseTabSpacing
    layout.sectionInset = NSEdgeInsets(top: topGap, left: 0, bottom: 0, right: 40)

    let collectionView = TabStripCollectionView()
    collectionView.collectionViewLayout = layout
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.isSelectable = true
    collectionView.allowsEmptySelection = true
    collectionView.backgroundColors = [.clear]
    collectionView.register(TabStripCollectionViewItem.self, forItemWithIdentifier: itemIdentifier)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    self.collectionView = collectionView

    let pinnedStack = NSStackView()
    pinnedStack.orientation = .horizontal
    pinnedStack.spacing = 6
    pinnedStack.alignment = .top
    pinnedStack.translatesAutoresizingMaskIntoConstraints = false
    self.pinnedStack = pinnedStack

    let leadingButton = TabStripSurfaceButton(
      symbolName: leadingAccessorySymbolName,
      pointSize: 17,
      weight: .medium,
      tintColor: .secondaryLabelColor
    )
    leadingButton.onTap = { [weak self, weak leadingButton] in
      guard let self, let leadingButton else { return }
      self.onLeadingAccessoryTap?(leadingButton)
    }
    self.leadingButton = leadingButton
    pinnedStack.addArrangedSubview(leadingButton)

    containerView.addSubview(collectionView)
    containerView.addSubview(pinnedStack)

    let pinnedLeadingConstraint = pinnedStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12)
    pinnedStackLeadingConstraint = pinnedLeadingConstraint

    NSLayoutConstraint.activate([
      pinnedLeadingConstraint,
      pinnedStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: topGap),
      pinnedStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

      collectionView.topAnchor.constraint(equalTo: containerView.topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: pinnedStack.trailingAnchor, constant: 4),
      collectionView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
    ])

    view = containerView
  }

  public func updateLeadingPadding(
    _ padding: CGFloat,
    animated: Bool = false,
    duration: TimeInterval = 0.2
  ) {
    guard pinnedStackLeadingConstraint?.constant != padding else { return }
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        pinnedStackLeadingConstraint?.animator().constant = padding
        view.layoutSubtreeIfNeeded()
      }
    } else {
      pinnedStackLeadingConstraint?.constant = padding
      view.layoutSubtreeIfNeeded()
    }
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    collectionView?.reloadData()
    selectCurrentItem()
  }

  public override func viewDidLayout() {
    super.viewDidLayout()
    updateLayoutForCurrentWidth()
    collectionView?.collectionViewLayout?.invalidateLayout()
  }

  public func update(
    items: [TabStripItem],
    selectedItemID: String?,
    selectionHidden: Bool = false
  ) {
    self.items = items
    self.selectedItemID = selectedItemID
    self.selectionHidden = selectionHidden

    guard isViewLoaded else { return }

    collectionView?.reloadData()
    selectCurrentItem()
  }

  public func setSelectionHidden(_ isHidden: Bool) {
    selectionHidden = isHidden
    guard isViewLoaded else { return }
    collectionView?.reloadData()
    selectCurrentItem()
  }

  private func selectCurrentItem() {
    guard let collectionView else { return }

    collectionView.deselectAll(nil)
    guard !selectionHidden, let selectedItemID else { return }

    guard let selectedIndex = items.firstIndex(where: { $0.id == selectedItemID }) else { return }
    let indexPath = IndexPath(item: selectedIndex, section: 0)
    collectionView.selectItems(at: [indexPath], scrollPosition: [])
  }

  private func updateLayoutForCurrentWidth() {
    guard let collectionView,
          let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout
    else { return }

    let availableWidth = max(
      collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right,
      1
    )
    let scale = layoutScale(forAvailableWidth: availableWidth)
    currentScale = scale
    layout.minimumInteritemSpacing = baseTabSpacing * scale

    collectionView.collectionViewLayout?.invalidateLayout()
    collectionView.collectionViewLayout?.prepare()
  }

  private func layoutScale(forAvailableWidth availableWidth: CGFloat) -> CGFloat {
    let tabCount = CGFloat(items.count)
    guard tabCount > 0 else { return 1 }

    let baseSpacingTotal = baseTabSpacing * max(0, tabCount - 1)
    let baseWidthTotal = items.reduce(CGFloat.zero) { sum, item in
      sum + baseWidth(for: item)
    }

    let denominator = baseWidthTotal + baseSpacingTotal
    guard denominator > 0 else { return 1 }

    return min(1, availableWidth / denominator)
  }

  private func baseWidth(for item: TabStripItem) -> CGFloat {
    switch item.style {
      case .home:
        return homeTabWidth
      case .standard:
        return TabStripCollectionViewItem.preferredWidth(for: item, iconSize: iconSize)
    }
  }
}

extension CollectionTabStripViewController: NSCollectionViewDataSource {
  public func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
    items.count
  }

  public func collectionView(
    _ collectionView: NSCollectionView,
    itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    guard indexPath.item < items.count else {
      return NSCollectionViewItem()
    }

    let item = items[indexPath.item]
    guard let collectionItem = collectionView.makeItem(
      withIdentifier: itemIdentifier,
      for: indexPath
    ) as? TabStripCollectionViewItem
    else {
      return NSCollectionViewItem()
    }

    let selected = selectedItemID == item.id && !selectionHidden
    let iconImage = iconProvider?(item.id)

    collectionItem.configure(
      with: item,
      iconSize: iconSize,
      scale: currentScale,
      selected: selected,
      iconImage: iconImage
    )
    collectionItem.onClose = { [weak self] in
      self?.onClose?(item.id)
    }

    return collectionItem
  }
}

extension CollectionTabStripViewController: NSCollectionViewDelegate {
  public func collectionView(_: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard let indexPath = indexPaths.first, indexPath.item < items.count else { return }
    onSelect?(items[indexPath.item].id)
  }
}

extension CollectionTabStripViewController: NSCollectionViewDelegateFlowLayout {
  public func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> NSSize {
    guard indexPath.item < items.count else { return NSSize(width: 0, height: tabHeight) }

    let item = items[indexPath.item]
    let baseWidth = baseWidth(for: item)

    guard let collectionView,
          let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout
    else {
      return NSSize(width: baseWidth, height: tabHeight)
    }

    let availableWidth = max(
      collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right,
      1
    )
    let scale = layoutScale(forAvailableWidth: availableWidth)
    currentScale = scale
    let scaledWidth = floor(baseWidth * scale)

    return NSSize(width: scaledWidth, height: tabHeight)
  }
}
