import AppKit
import InlineKit

final class RichBlockAlbumNodeView: RichBlockRenderableView {
  private static let itemIdentifier = NSUserInterfaceItemIdentifier("RichBlockAlbumCollectionItem")

  private let flowLayout: NSCollectionViewFlowLayout = {
    let layout = NSCollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.minimumInteritemSpacing = 6
    layout.minimumLineSpacing = 6
    layout.sectionInset = NSEdgeInsets()
    return layout
  }()

  private lazy var collectionView: NSCollectionView = {
    let view = NSCollectionView()
    view.collectionViewLayout = flowLayout
    view.dataSource = self
    view.delegate = self
    view.isSelectable = false
    view.backgroundColors = [.clear]
    view.register(
      RichBlockAlbumCollectionItem.self,
      forItemWithIdentifier: Self.itemIdentifier
    )
    return view
  }()

  private lazy var scrollView: RichBlockHorizontalScrollView = {
    let view = RichBlockHorizontalScrollView()
    view.borderType = .noBorder
    view.drawsBackground = false
    view.backgroundColor = .clear
    view.contentView.drawsBackground = false
    view.hasHorizontalScroller = false
    view.hasVerticalScroller = false
    view.autohidesScrollers = true
    view.horizontalScrollElasticity = .automatic
    view.verticalScrollElasticity = .none
    view.documentView = collectionView
    return view
  }()

  private var items: [RichBlockLayoutPlan.ImageNode] = []
  private var context: RichBlockRenderContext?
  private var contentWidth: CGFloat = 0
  private var leadingInset: CGFloat = 0

  init() {
    super.init(reuseKind: .album)
    wantsLayer = true
    clipsToBounds = true
    addSubview(scrollView)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Image album")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .album(album) = node.kind else { return }
    let preservedOffset = scrollView.contentView.bounds.minX
    let preservesTopology = items.count == album.items.count
      && zip(items, album.items).allSatisfy { previous, current in
        previous.path == current.path
      }
    items = album.items
    self.context = context
    leadingInset = context.renderStyle == .bubble ? context.contentHorizontalInset : 0
    contentWidth = items.map { $0.frame.maxX }.max() ?? 0
    if preservesTopology {
      for index in items.indices {
        guard let item = collectionView.item(
          at: IndexPath(item: index, section: 0)
        ) as? RichBlockAlbumCollectionItem else { continue }
        item.apply(image: items[index], context: context)
        item.setContentVisible(isContentVisible)
      }
      flowLayout.invalidateLayout()
    } else {
      collectionView.reloadData()
    }
    restoreHorizontalOffset(preservedOffset)
    needsLayout = true
  }

  override func setContentVisible(_ visible: Bool) {
    super.setContentVisible(visible)
    for case let item as RichBlockAlbumCollectionItem in collectionView.visibleItems() {
      item.setContentVisible(visible)
    }
  }

  override func layout() {
    super.layout()
    let preservedOffset = scrollView.contentView.bounds.minX
    scrollView.frame = CGRect(
      x: leadingInset,
      y: bounds.minY,
      width: max(0, bounds.width - leadingInset),
      height: bounds.height
    )
    let viewportWidth = scrollView.contentSize.width
    collectionView.frame = CGRect(
      x: 0,
      y: 0,
      width: max(viewportWidth, contentWidth),
      height: bounds.height
    )
    flowLayout.invalidateLayout()
    collectionView.layoutSubtreeIfNeeded()
    restoreHorizontalOffset(preservedOffset)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    items = []
    context = nil
    contentWidth = 0
    leadingInset = 0
    collectionView.reloadData()
    restoreHorizontalOffset(0)
  }

  private func restoreHorizontalOffset(_ proposedOffset: CGFloat) {
    let maximumOffset = max(0, contentWidth - scrollView.contentSize.width)
    scrollView.contentView.scroll(
      to: CGPoint(x: min(max(0, proposedOffset), maximumOffset), y: 0)
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
}

extension RichBlockAlbumNodeView: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
  func numberOfSections(in _: NSCollectionView) -> Int {
    1
  }

  func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
    items.count
  }

  func collectionView(
    _ collectionView: NSCollectionView,
    itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    guard let item = collectionView.makeItem(
      withIdentifier: Self.itemIdentifier,
      for: indexPath
    ) as? RichBlockAlbumCollectionItem,
      items.indices.contains(indexPath.item),
      let context
    else { return NSCollectionViewItem() }
    item.apply(image: items[indexPath.item], context: context)
    item.setContentVisible(isContentVisible)
    return item
  }

  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> NSSize {
    guard items.indices.contains(indexPath.item) else { return .zero }
    return items[indexPath.item].frame.size
  }
}

private final class RichBlockAlbumCollectionItem: NSCollectionViewItem {
  private let imageNodeView = RichBlockImageNodeView()

  override func loadView() {
    view = RichBlockAlbumItemContainerView(frame: .zero)
    view.addSubview(imageNodeView)
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    imageNodeView.frame = view.bounds
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    imageNodeView.prepareForReuse()
  }

  func apply(image: RichBlockLayoutPlan.ImageNode, context: RichBlockRenderContext) {
    loadViewIfNeeded()
    imageNodeView.apply(image: image, context: context)
    imageNodeView.frame = view.bounds
  }

  func setContentVisible(_ visible: Bool) {
    imageNodeView.setContentVisible(visible)
  }
}

private final class RichBlockAlbumItemContainerView: NSView {
  override var isFlipped: Bool { true }
}
