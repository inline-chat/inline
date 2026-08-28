import AppKit
import InlineKit
import InlineMacUI

protocol ComposeAutocompleteMenuDelegate: AnyObject {
  func autocompleteMenu(_ menu: ComposeAutocompleteMenu, didSelect item: ComposeAutocompleteItem)
  func autocompleteMenuDidRequestClose(_ menu: ComposeAutocompleteMenu)
}

final class ComposeAutocompleteMenu: ComposeCompletionMenuView {
  weak var delegate: ComposeAutocompleteMenuDelegate?

  private let scrollView = ComposeAutocompleteScrollView()
  private let tableView = NSTableView()
  private let paletteScrollView = ComposeAutocompleteScrollView()
  private let paletteLayout = NSCollectionViewFlowLayout()
  private let collectionView = ComposeAutocompleteCollectionView()
  private let surfaceView: ComposeCompletionSurfaceView

  private var items: [ComposeAutocompleteItem] = []
  private var selectedIndex = 0
  private var availableWidth: CGFloat?
  private var style: Style = .list
  private(set) var canSelectItems = true
  private(set) var presentationSession: ComposeAutocompletePresentationSession?
  private var heightConstraint: NSLayoutConstraint!
  private var widthConstraint: NSLayoutConstraint!

  var isShowingEmojiPalette: Bool {
    style == .emojiPalette
  }

  private enum Style {
    case list
    case emojiPalette
  }

  enum Layout {
    static let listWidth: CGFloat = 340
    static let maxHeight: CGFloat = 184
    static let rowHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 16
    static let paletteItemSize: CGFloat = 34
    static let paletteHeight: CGFloat = 42
    static let paletteSpacing: CGFloat = 0
    static let paletteHorizontalInset: CGFloat = 6
    static let paletteVerticalInset: CGFloat = 4
    static let paletteMinVisibleItems = 4
    static let paletteMaxVisibleItems = 7
  }

  init(surfaceStyle: ComposeCompletionSurfaceStyle) {
    surfaceView = ComposeCompletionSurfaceView(
      style: surfaceStyle,
      cornerRadius: Layout.cornerRadius
    )
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var isVisible: Bool { isPresented }

  override func layout() {
    super.layout()
    if style == .list, bounds.width > 1 {
      tableView.tableColumns.first?.width = bounds.width
    }
    updateLayerGeometry()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackdropAppearance()
  }

  func update(
    items: [ComposeAutocompleteItem],
    selectedIndex: Int,
    match: ComposeAutocompleteMatch,
    availableWidth: CGFloat? = nil
  ) {
    let nextStyle: Style = items.allSatisfy { $0.kind == .emoji } ? .emojiPalette : .list
    let needsReload = self.items != items || style != nextStyle
    let needsResize = self.availableWidth != availableWidth

    presentationSession = ComposeAutocompletePresentationSession(match: match)
    setContentInteractionEnabled(true)
    self.items = items
    self.selectedIndex = items.indices.contains(selectedIndex) ? selectedIndex : 0
    self.availableWidth = availableWidth
    style = nextStyle

    if needsReload {
      updateContent()
    } else {
      if needsResize {
        updateSize()
      }
      updateSelection()
    }
  }

  func setSelectedIndex(_ selectedIndex: Int) {
    guard canSelectItems, items.indices.contains(selectedIndex) else { return }
    self.selectedIndex = selectedIndex
    updateSelection()
  }

  func setAvailableWidth(_ availableWidth: CGFloat) {
    guard availableWidth > 1, self.availableWidth != availableWidth else { return }
    self.availableWidth = availableWidth
    updateSize()
  }

  @discardableResult
  func retainVisibleContentWhileLoading() -> Bool {
    guard isVisible, !items.isEmpty
    else {
      return false
    }

    setContentInteractionEnabled(false)
    return true
  }

  func show(animated: Bool = true) {
    guard !items.isEmpty else {
      hide(animated: false)
      return
    }

    present(animated: animated)
  }

  func hide(animated: Bool = true) {
    presentationSession = nil
    setContentInteractionEnabled(true)
    dismiss(animated: animated)
  }

  @discardableResult
  func selectCurrentItem() -> Bool {
    guard canSelectItems, items.indices.contains(selectedIndex) else { return false }
    delegate?.autocompleteMenu(self, didSelect: items[selectedIndex])
    return true
  }

  private func setContentInteractionEnabled(_ isEnabled: Bool) {
    guard canSelectItems != isEnabled else { return }
    canSelectItems = isEnabled
    collectionView.isSelectable = isEnabled
  }

  private func setupView() {
    wantsLayer = true
    layer?.shadowOffset = NSSize(width: 0, height: -8)
    layer?.shadowRadius = 22
    layer?.masksToBounds = false
    addSubview(surfaceView)

    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.wantsLayer = true
    scrollView.layer?.masksToBounds = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hideScrollers()

    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.style = .plain
    tableView.allowsEmptySelection = false
    tableView.delegate = self
    tableView.dataSource = self
    tableView.target = self
    tableView.action = #selector(tableViewClicked)
    tableView.focusRingType = .none
    tableView.selectionHighlightStyle = .none
    tableView.intercellSpacing = .zero
    tableView.refusesFirstResponder = true

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("autocomplete"))
    column.width = Layout.listWidth
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    scrollView.documentView = tableView
    addSubview(scrollView)

    paletteLayout.scrollDirection = .horizontal
    paletteLayout.itemSize = NSSize(width: Layout.paletteItemSize, height: Layout.paletteItemSize)
    paletteLayout.minimumLineSpacing = Layout.paletteSpacing
    paletteLayout.minimumInteritemSpacing = Layout.paletteSpacing
    paletteLayout.sectionInset = NSEdgeInsets(
      top: Layout.paletteVerticalInset,
      left: Layout.paletteHorizontalInset,
      bottom: Layout.paletteVerticalInset,
      right: Layout.paletteHorizontalInset
    )

    collectionView.collectionViewLayout = paletteLayout
    collectionView.backgroundColors = [.clear]
    collectionView.isSelectable = true
    collectionView.allowsMultipleSelection = false
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(
      ComposeEmojiAutocompletePaletteItem.self,
      forItemWithIdentifier: ComposeEmojiAutocompletePaletteItem.identifier
    )
    collectionView.translatesAutoresizingMaskIntoConstraints = false

    paletteScrollView.hasVerticalScroller = false
    paletteScrollView.hasHorizontalScroller = false
    paletteScrollView.autohidesScrollers = true
    paletteScrollView.scrollerStyle = .overlay
    paletteScrollView.borderType = .noBorder
    paletteScrollView.drawsBackground = false
    paletteScrollView.wantsLayer = true
    paletteScrollView.layer?.masksToBounds = true
    paletteScrollView.documentView = collectionView
    paletteScrollView.hideScrollers()
    paletteScrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(paletteScrollView)

    heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    widthConstraint = widthAnchor.constraint(equalToConstant: Layout.listWidth)
    widthConstraint.priority = .defaultHigh
    let constraints: [NSLayoutConstraint] = [
      heightConstraint,
      widthConstraint,
      surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
      surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
      surfaceView.topAnchor.constraint(equalTo: topAnchor),
      surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      paletteScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      paletteScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      paletteScrollView.topAnchor.constraint(equalTo: topAnchor),
      paletteScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]

    NSLayoutConstraint.activate(constraints)

    updateLayerGeometry()
    updateBackdropAppearance()
    updateVisibleContent()
  }

  private func updateContent() {
    updateVisibleContent()
    updateSize()

    switch style {
    case .list:
      tableView.reloadData()
    case .emojiPalette:
      collectionView.reloadData()
    }
    updateSelection()
  }

  private func updateVisibleContent() {
    switch style {
    case .list:
      scrollView.isHidden = false
      paletteScrollView.isHidden = true
    case .emojiPalette:
      scrollView.isHidden = true
      paletteScrollView.isHidden = false
    }
    updateLayerGeometry()
    updateBackdropAppearance()
  }

  private func updateSize() {
    let newHeight: CGFloat
    let newWidth: CGFloat

    switch style {
    case .list:
      newHeight = min(CGFloat(items.count) * Layout.rowHeight, Layout.maxHeight)
      newWidth = availableWidth.flatMap { $0 > 0 ? $0 : nil } ?? Layout.listWidth
      tableView.tableColumns.first?.width = newWidth
    case .emojiPalette:
      newHeight = Layout.paletteHeight
      newWidth = availableWidth.flatMap { $0 > 0 ? $0 : nil } ?? naturalPaletteWidth()
    }

    setHeight(newHeight, constraint: heightConstraint)
    widthConstraint.constant = newWidth
  }

  private func naturalPaletteWidth() -> CGFloat {
    let visibleItems = min(
      max(items.count, Layout.paletteMinVisibleItems),
      Layout.paletteMaxVisibleItems
    )
    let itemWidth = CGFloat(visibleItems) * Layout.paletteItemSize
    let spacingWidth = CGFloat(max(visibleItems - 1, 0)) * Layout.paletteSpacing
    return itemWidth + spacingWidth + Layout.paletteHorizontalInset * 2
  }

  private func updateSelection() {
    guard !items.isEmpty else { return }

    switch style {
    case .list:
      tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
      tableView.scrollRowToVisible(selectedIndex)

      for row in 0 ..< items.count {
        if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ComposeAutocompleteMenuItem {
          cellView.isSelected = row == selectedIndex
        }
      }
    case .emojiPalette:
      let indexPath = IndexPath(item: selectedIndex, section: 0)
      collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredHorizontally)
      paletteScrollView.hideScrollers()

      for visibleIndexPath in collectionView.indexPathsForVisibleItems() {
        if let item = collectionView.item(at: visibleIndexPath) as? ComposeEmojiAutocompletePaletteItem {
          item.isActive = visibleIndexPath.item == selectedIndex
        }
      }
    }
  }

  private func updateBackdropAppearance() {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.shadowColor = NSColor.black.cgColor
    switch style {
    case .list:
      layer?.shadowOffset = NSSize(width: 0, height: -6)
      layer?.shadowRadius = 14
      layer?.shadowOpacity = isDark ? 0.22 : 0.12
    case .emojiPalette:
      layer?.shadowOffset = NSSize(width: 0, height: -6)
      layer?.shadowRadius = 10
      layer?.shadowOpacity = isDark ? 0.18 : 0.10
    }
  }

  private func updateLayerGeometry() {
    let cornerRadius = currentCornerRadius

    layer?.cornerRadius = cornerRadius
    layer?.cornerCurve = .continuous
    surfaceView.cornerRadius = cornerRadius
    layer?.shadowPath = CGPath(
      roundedRect: bounds,
      cornerWidth: cornerRadius,
      cornerHeight: cornerRadius,
      transform: nil
    )

    scrollView.layer?.cornerRadius = cornerRadius
    paletteScrollView.layer?.cornerRadius = cornerRadius
    paletteLayout.itemSize = NSSize(width: Layout.paletteItemSize, height: Layout.paletteItemSize)
    paletteLayout.sectionInset = NSEdgeInsets(
      top: Layout.paletteVerticalInset,
      left: Layout.paletteHorizontalInset,
      bottom: Layout.paletteVerticalInset,
      right: Layout.paletteHorizontalInset
    )
  }

  private var currentCornerRadius: CGFloat {
    switch style {
    case .list:
      Layout.cornerRadius
    case .emojiPalette:
      max(bounds.height / 2, Layout.paletteHeight / 2)
    }
  }

  @objc private func tableViewClicked() {
    let clickedRow = tableView.clickedRow
    guard canSelectItems, items.indices.contains(clickedRow) else { return }
    selectedIndex = clickedRow
    DispatchQueue.main.async { [weak self] in
      _ = self?.selectCurrentItem()
    }
  }
}

private final class ComposeAutocompleteScrollView: NSScrollView {
  override var acceptsFirstResponder: Bool { false }

  override func becomeFirstResponder() -> Bool {
    false
  }

  override func flashScrollers() {}

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    hideScrollers()
  }

  override func tile() {
    super.tile()
    hideScrollers()
  }

  func hideScrollers() {
    hasVerticalScroller = false
    hasHorizontalScroller = false
    verticalScroller?.isHidden = true
    horizontalScroller?.isHidden = true
  }
}

private final class ComposeAutocompleteCollectionView: NSCollectionView {
  override var acceptsFirstResponder: Bool { false }

  override func becomeFirstResponder() -> Bool {
    false
  }
}

extension ComposeAutocompleteMenu: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    items.count
  }
}

extension ComposeAutocompleteMenu: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("AutocompleteCell")
    let cellView = (tableView.makeView(withIdentifier: identifier, owner: self) as? ComposeAutocompleteMenuItem) ?? {
      let view = ComposeAutocompleteMenuItem()
      view.identifier = identifier
      return view
    }()

    if items.indices.contains(row) {
      cellView.configure(with: items[row])
      cellView.isSelected = row == selectedIndex
    }

    return cellView
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    Layout.rowHeight
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    guard canSelectItems else { return false }
    selectedIndex = row
    updateSelection()
    return true
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    if canSelectItems, tableView.selectedRow >= 0 {
      selectedIndex = tableView.selectedRow
      updateSelection()
    }
  }
}

extension ComposeAutocompleteMenu: NSCollectionViewDataSource {
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
    items.count
  }

  func collectionView(
    _ collectionView: NSCollectionView,
    itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    let itemView = collectionView.makeItem(
      withIdentifier: ComposeEmojiAutocompletePaletteItem.identifier,
      for: indexPath
    )

    if let paletteItem = itemView as? ComposeEmojiAutocompletePaletteItem,
       items.indices.contains(indexPath.item) {
      paletteItem.configure(with: items[indexPath.item], selected: indexPath.item == selectedIndex)
    }

    return itemView
  }
}

extension ComposeAutocompleteMenu: NSCollectionViewDelegate {
  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard canSelectItems,
          let indexPath = indexPaths.first,
          items.indices.contains(indexPath.item)
    else {
      return
    }
    selectedIndex = indexPath.item
    DispatchQueue.main.async { [weak self] in
      _ = self?.selectCurrentItem()
    }
  }
}
