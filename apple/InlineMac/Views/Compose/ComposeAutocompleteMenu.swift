import AppKit
import InlineKit
import SwiftUI

protocol ComposeAutocompleteMenuDelegate: AnyObject {
  func autocompleteMenu(_ menu: ComposeAutocompleteMenu, didSelect item: ComposeAutocompleteItem)
  func autocompleteMenuDidRequestClose(_ menu: ComposeAutocompleteMenu)
}

final class ComposeAutocompleteMenu: NSView {
  weak var delegate: ComposeAutocompleteMenuDelegate?

  private let scrollView = ComposeAutocompleteScrollView()
  private let tableView = NSTableView()
  private let paletteScrollView = ComposeAutocompleteScrollView()
  private let paletteLayout = NSCollectionViewFlowLayout()
  private let collectionView = ComposeAutocompleteCollectionView()
  private let backgroundView = NSVisualEffectView()
  private let backgroundFillView = NSView()
  private var glassBackgroundView: NSView?

  private var items: [ComposeAutocompleteItem] = []
  private var selectedIndex = 0
  private var availableWidth: CGFloat?
  private var style: Style = .list
  private(set) var isVisible = false
  private var heightConstraint: NSLayoutConstraint!
  private var widthConstraint: NSLayoutConstraint!

  var preferredWidth: CGFloat {
    widthConstraint?.constant ?? Layout.listWidth
  }

  var isShowingEmojiPalette: Bool {
    style == .emojiPalette
  }

  private enum Style {
    case list
    case emojiPalette
  }

  enum Layout {
    static let listWidth: CGFloat = 340
    static let listMinWidth: CGFloat = 280
    static let maxHeight: CGFloat = 184
    static let rowHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 12
    static let paletteItemSize: CGFloat = 34
    static let paletteHeight: CGFloat = 42
    static let paletteSpacing: CGFloat = 0
    static let paletteHorizontalInset: CGFloat = 6
    static let paletteVerticalInset: CGFloat = 4
    static let paletteMinVisibleItems = 4
    static let paletteMaxVisibleItems = 7
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool { false }

  override func layout() {
    super.layout()
    updateLayerGeometry()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackdropAppearance()
  }

  func update(items: [ComposeAutocompleteItem], selectedIndex: Int, availableWidth: CGFloat? = nil) {
    let nextStyle: Style = items.allSatisfy { $0.kind == .emoji } ? .emojiPalette : .list
    let needsReload = self.items != items || style != nextStyle
    let needsResize = self.availableWidth != availableWidth

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
    guard items.indices.contains(selectedIndex) else { return }
    self.selectedIndex = selectedIndex
    updateSelection()
  }

  func show(animated: Bool = true) {
    guard !items.isEmpty else {
      hide(animated: false)
      return
    }

    guard !isVisible else { return }
    isVisible = true
    isHidden = false

    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animator().alphaValue = 1.0
      }
    } else {
      alphaValue = 1.0
    }
  }

  func hide(animated: Bool = true) {
    guard isVisible || !isHidden else { return }
    isVisible = false

    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.1
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        animator().alphaValue = 0.0
      } completionHandler: { [weak self] in
        self?.isHidden = true
      }
    } else {
      alphaValue = 0.0
      isHidden = true
    }
  }

  @discardableResult
  func selectCurrentItem() -> Bool {
    guard items.indices.contains(selectedIndex) else { return false }
    delegate?.autocompleteMenu(self, didSelect: items[selectedIndex])
    return true
  }

  private func setupView() {
    wantsLayer = true
    layer?.borderWidth = 1
    layer?.shadowOffset = NSSize(width: 0, height: -8)
    layer?.shadowRadius = 22
    layer?.masksToBounds = false

    if #available(macOS 26.0, *) {
      let glassBackgroundView = ComposeAutocompletePaletteGlassBackgroundView()
      glassBackgroundView.translatesAutoresizingMaskIntoConstraints = false
      self.glassBackgroundView = glassBackgroundView
      addSubview(glassBackgroundView)
    }

    backgroundView.material = .menu
    backgroundView.blendingMode = .withinWindow
    backgroundView.state = .active
    backgroundView.wantsLayer = true
    backgroundView.layer?.masksToBounds = true
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)

    backgroundFillView.wantsLayer = true
    backgroundFillView.layer?.masksToBounds = true
    backgroundFillView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundFillView)

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
    var constraints: [NSLayoutConstraint] = [
      heightConstraint,
      widthConstraint,
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
      backgroundFillView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundFillView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundFillView.topAnchor.constraint(equalTo: topAnchor),
      backgroundFillView.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      paletteScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      paletteScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      paletteScrollView.topAnchor.constraint(equalTo: topAnchor),
      paletteScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]

    if let glassBackgroundView {
      constraints.append(contentsOf: [
        glassBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
        glassBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
        glassBackgroundView.topAnchor.constraint(equalTo: topAnchor),
        glassBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    NSLayoutConstraint.activate(constraints)

    alphaValue = 0
    isHidden = true
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
      glassBackgroundView?.isHidden = true
      backgroundView.isHidden = false
      backgroundFillView.isHidden = false
    case .emojiPalette:
      scrollView.isHidden = true
      paletteScrollView.isHidden = false
      if #available(macOS 26.0, *) {
        glassBackgroundView?.isHidden = false
        backgroundView.isHidden = true
        backgroundFillView.isHidden = true
      } else {
        glassBackgroundView?.isHidden = true
        backgroundView.isHidden = false
        backgroundFillView.isHidden = false
      }
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
      newWidth = availableWidth.flatMap { $0 > 0 ? max($0, Layout.listMinWidth) : nil } ?? Layout.listWidth
      tableView.tableColumns.first?.width = newWidth
    case .emojiPalette:
      newHeight = Layout.paletteHeight
      newWidth = availableWidth.flatMap { $0 > 0 ? $0 : nil } ?? naturalPaletteWidth()
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = ModernTimingFunctions.snappy
      heightConstraint.animator().constant = newHeight
      widthConstraint.animator().constant = newWidth
    }
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
    let fillColor: NSColor
    let borderColor: NSColor

    switch style {
    case .list:
      fillColor = isDark
        ? NSColor(calibratedWhite: 0.16, alpha: 0.70)
        : NSColor(calibratedWhite: 1.00, alpha: 0.78)
      borderColor = .clear
    case .emojiPalette:
      fillColor = isDark
        ? NSColor(calibratedWhite: 0.16, alpha: 0.55)
        : NSColor(calibratedWhite: 1.00, alpha: 0.62)
      borderColor = .clear
    }

    backgroundFillView.layer?.backgroundColor = resolvedCGColor(fillColor)
    layer?.borderColor = resolvedCGColor(borderColor)
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
    layer?.borderWidth = 0
    layer?.shadowPath = CGPath(
      roundedRect: bounds,
      cornerWidth: cornerRadius,
      cornerHeight: cornerRadius,
      transform: nil
    )

    backgroundView.layer?.cornerRadius = cornerRadius
    backgroundFillView.layer?.cornerRadius = cornerRadius
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

  private func resolvedCGColor(_ color: NSColor) -> CGColor {
    color.resolvedColor(with: effectiveAppearance).cgColor
  }

  @objc private func tableViewClicked() {
    let clickedRow = tableView.clickedRow
    guard items.indices.contains(clickedRow) else { return }
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
    selectedIndex = row
    updateSelection()
    return true
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    if tableView.selectedRow >= 0 {
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
       items.indices.contains(indexPath.item)
    {
      paletteItem.configure(with: items[indexPath.item], selected: indexPath.item == selectedIndex)
    }

    return itemView
  }
}

extension ComposeAutocompleteMenu: NSCollectionViewDelegate {
  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard let indexPath = indexPaths.first, items.indices.contains(indexPath.item) else { return }
    selectedIndex = indexPath.item
    DispatchQueue.main.async { [weak self] in
      _ = self?.selectCurrentItem()
    }
  }
}

@available(macOS 26.0, *)
private final class ComposeAutocompletePaletteGlassBackgroundView: NSView {
  private let hostingView = NSHostingView(rootView: ComposeAutocompletePaletteGlassBackground())

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor

    addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

@available(macOS 26.0, *)
private struct ComposeAutocompletePaletteGlassBackground: View {
  var body: some View {
    GlassEffectContainer(spacing: 0) {
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
    .allowsHitTesting(false)
  }
}
