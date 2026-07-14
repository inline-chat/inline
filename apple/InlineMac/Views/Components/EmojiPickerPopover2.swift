import AppKit
import CoreText
import QuartzCore
import SwiftUI
import TextProcessing

struct EmojiPickerPopover2: View {
  var onSelect: (String) -> Void

  static var preferredContentSize: NSSize {
    NSSize(width: EmojiPicker2Layout.width, height: EmojiPicker2Layout.height)
  }

  var body: some View {
    EmojiPicker2AppKitView(onSelect: onSelect)
      .frame(width: Self.preferredContentSize.width, height: Self.preferredContentSize.height)
      .fixedSize()
  }

  @MainActor
  static func makeViewController(onSelect: @escaping (String) -> Void) -> NSViewController {
    EmojiPicker2ViewController(onSelect: onSelect)
  }

  @MainActor
  static func makePopover(onSelect: @escaping (String) -> Void) -> NSPopover {
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.contentSize = preferredContentSize
    popover.contentViewController = makeViewController { [weak popover] emoji in
      onSelect(emoji)
      popover?.performClose(nil)
    }
    return popover
  }
}

struct EmojiPickerPopoverPresenter2: NSViewRepresentable {
  @Binding var isPresented: Bool
  var preferredEdge: NSRectEdge = .maxY
  var onSelect: (String) -> Void
  var onDismiss: () -> Void = {}

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context _: Context) -> EmojiPickerPopoverAnchorView2 {
    EmojiPickerPopoverAnchorView2()
  }

  func updateNSView(_ view: EmojiPickerPopoverAnchorView2, context: Context) {
    context.coordinator.update(configuration: self, anchorView: view)
  }

  static func dismantleNSView(_ nsView: EmojiPickerPopoverAnchorView2, coordinator: Coordinator) {
    coordinator.closePopover(sendDismiss: false)
  }

  @MainActor
  final class Coordinator: NSObject, NSPopoverDelegate {
    private var configuration: EmojiPickerPopoverPresenter2?
    private weak var anchorView: NSView?
    private var popover: NSPopover?
    private var isPresentationDeferred = false

    func update(configuration: EmojiPickerPopoverPresenter2, anchorView: NSView) {
      self.configuration = configuration
      self.anchorView = anchorView

      if configuration.isPresented {
        showPopover(from: anchorView)
      } else {
        closePopover(sendDismiss: false)
      }
    }

    func closePopover(sendDismiss: Bool) {
      guard let popover else { return }

      if sendDismiss, let configuration, configuration.isPresented {
        configuration.isPresented = false
        configuration.onDismiss()
      }

      popover.delegate = nil
      popover.performClose(nil)
      self.popover = nil
    }

    private func showPopover(from anchorView: NSView) {
      guard let configuration else { return }

      guard anchorView.window != nil else {
        deferPresentation()
        return
      }

      guard popover?.isShown != true else { return }

      let popover = EmojiPickerPopover2.makePopover { [weak self] emoji in
        guard let self, let configuration = self.configuration else { return }
        configuration.onSelect(emoji)
        configuration.isPresented = false
      }
      popover.delegate = self
      self.popover = popover
      popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: configuration.preferredEdge)
    }

    private func deferPresentation() {
      guard !isPresentationDeferred else { return }
      isPresentationDeferred = true

      Task { @MainActor [weak self] in
        guard let self else { return }
        isPresentationDeferred = false
        guard let configuration, configuration.isPresented, let anchorView else { return }
        showPopover(from: anchorView)
      }
    }

    func popoverDidClose(_ notification: Notification) {
      guard notification.object as? NSPopover === popover else { return }
      popover = nil

      guard let configuration, configuration.isPresented else { return }
      configuration.isPresented = false
      configuration.onDismiss()
    }
  }
}

final class EmojiPickerPopoverAnchorView2: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

private struct EmojiPicker2AppKitView: NSViewRepresentable {
  var onSelect: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onSelect: onSelect)
  }

  func makeNSView(context: Context) -> EmojiPicker2RootView {
    let view = EmojiPicker2RootView(frame: NSRect(origin: .zero, size: EmojiPickerPopover2.preferredContentSize))
    view.delegate = context.coordinator
    return view
  }

  func updateNSView(_ view: EmojiPicker2RootView, context: Context) {
    context.coordinator.onSelect = onSelect
    view.delegate = context.coordinator
  }

  final class Coordinator: NSObject, EmojiPicker2RootViewDelegate {
    var onSelect: (String) -> Void

    init(onSelect: @escaping (String) -> Void) {
      self.onSelect = onSelect
    }

    func emojiPicker2RootView(_: EmojiPicker2RootView, didSelect emoji: String) {
      onSelect(emoji)
    }
  }
}

private final class EmojiPicker2ViewController: NSViewController, EmojiPicker2RootViewDelegate {
  private var onSelect: (String) -> Void

  init(onSelect: @escaping (String) -> Void) {
    self.onSelect = onSelect
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = EmojiPickerPopover2.preferredContentSize
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let view = EmojiPicker2RootView(frame: NSRect(origin: .zero, size: EmojiPickerPopover2.preferredContentSize))
    view.delegate = self
    self.view = view
  }

  func emojiPicker2RootView(_: EmojiPicker2RootView, didSelect emoji: String) {
    onSelect(emoji)
  }
}

@MainActor
private protocol EmojiPicker2RootViewDelegate: AnyObject {
  func emojiPicker2RootView(_ view: EmojiPicker2RootView, didSelect emoji: String)
}

@MainActor
private final class EmojiPicker2RootView: NSView {
  weak var delegate: EmojiPicker2RootViewDelegate?

  private let backgroundView = NSVisualEffectView()
  private let searchBar = EmojiPicker2BarView(separatorEdge: .bottom)
  private let searchField = EmojiPicker2SearchField()
  private let scrollView = EmojiPicker2ScrollView()
  private let collectionView = EmojiPicker2CollectionView()
  private let collectionLayout = NSCollectionViewFlowLayout()
  private let emptyLabel = NSTextField(labelWithString: "No emoji found")
  private let categoryBar = EmojiPicker2BarView(separatorEdge: .top)

  private var sections = EmojiPickerData.defaultSections
  private var query = ""
  private var didFocusSearch = false
  private var hoveredIndexPath: IndexPath?
  private var categoryButtons: [EmojiPicker2CategoryButton] = []
  private var lastLayoutWidth: CGFloat = 0
  private var preloadedImageScaleKeys = Set<Int>()

  private let tabs = EmojiPicker2CategoryTab.makeTabs(from: EmojiPickerData.defaultSections)
  private let imageCache = EmojiPicker2ImageCache.shared

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
    setupSearchField()
    setupCollectionView()
    setupCategories()
    applySections(EmojiPickerData.defaultSections, resetScroll: true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    EmojiPickerPopover2.preferredContentSize
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    guard window != nil else {
      updateHoveredIndexPath(nil)
      return
    }

    preloadImagesForCurrentScale()

    guard !didFocusSearch else { return }
    didFocusSearch = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      window?.makeFirstResponder(searchField)
    }
  }

  override func layout() {
    super.layout()

    let searchHeight = EmojiPicker2Layout.searchBarHeight
    let categoryHeight = EmojiPicker2Layout.categoryBarHeight
    let collectionHeight = max(0, bounds.height - searchHeight - categoryHeight)

    backgroundView.frame = bounds
    categoryBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: categoryHeight)
    scrollView.frame = NSRect(x: 0, y: categoryHeight, width: bounds.width, height: collectionHeight)
    searchBar.frame = NSRect(x: 0, y: bounds.height - searchHeight, width: bounds.width, height: searchHeight)
    searchBar.layoutSubtreeIfNeeded()
    categoryBar.layoutSubtreeIfNeeded()
    emptyLabel.frame = NSRect(
      x: scrollView.frame.minX + 16,
      y: scrollView.frame.minY + floor((collectionHeight - 20) / 2),
      width: max(0, scrollView.frame.width - 32),
      height: 20
    )

    layoutSearchField()
    layoutCategoryButtons()
    updateCollectionLayoutMetrics()
    syncDocumentFrame()
    preloadImagesForCurrentScale()
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    setContentHuggingPriority(.required, for: .horizontal)
    setContentHuggingPriority(.required, for: .vertical)
    setContentCompressionResistancePriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .vertical)

    backgroundView.material = .popover
    backgroundView.blendingMode = .withinWindow
    backgroundView.state = .active
    addSubview(backgroundView)

    addSubview(scrollView)

    emptyLabel.font = .systemFont(ofSize: 12)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.isHidden = true
    addSubview(emptyLabel)

    addSubview(searchBar)
    addSubview(categoryBar)
  }

  private func setupSearchField() {
    searchField.placeholderString = "Search emoji"
    searchField.controlSize = .regular
    searchField.font = .systemFont(ofSize: NSFont.systemFontSize(for: searchField.controlSize))
    searchField.focusRingType = .default
    searchField.sendsSearchStringImmediately = true
    searchField.sendsWholeSearchString = false
    searchField.delegate = self
    searchField.target = self
    searchField.action = #selector(searchChanged(_:))
    searchField.setAccessibilityLabel("Search emoji")
    searchBar.contentView.addSubview(searchField)
  }

  private func setupCollectionView() {
    collectionLayout.scrollDirection = .vertical
    collectionLayout.itemSize = NSSize(width: EmojiPicker2Layout.itemSize, height: EmojiPicker2Layout.itemSize)
    collectionLayout.minimumInteritemSpacing = EmojiPicker2Layout.itemSpacing
    collectionLayout.minimumLineSpacing = EmojiPicker2Layout.itemSpacing
    collectionLayout.sectionInset = EmojiPicker2Layout.collectionSectionInset(for: EmojiPicker2Layout.width)
    collectionLayout.headerReferenceSize = NSSize(
      width: EmojiPicker2Layout.width,
      height: EmojiPicker2Layout.sectionHeaderHeight
    )

    collectionView.collectionViewLayout = collectionLayout
    collectionView.backgroundColors = [.clear]
    collectionView.wantsLayer = true
    collectionView.layer?.backgroundColor = NSColor.clear.cgColor
    collectionView.isSelectable = true
    collectionView.allowsMultipleSelection = false
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.hoverDelegate = self
    collectionView.register(
      EmojiPicker2CollectionItem.self,
      forItemWithIdentifier: EmojiPicker2CollectionItem.identifier
    )
    collectionView.register(
      EmojiPicker2HeaderView.self,
      forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
      withIdentifier: EmojiPicker2HeaderView.identifier
    )

    scrollView.drawsBackground = false
    scrollView.contentView.drawsBackground = false
    scrollView.contentView.backgroundColor = .clear
    scrollView.contentView.automaticallyAdjustsContentInsets = false
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.borderType = .noBorder
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.verticalScrollElasticity = .allowed
    scrollView.scrollerStyle = .overlay
    scrollView.didScroll = { [weak self] in
      self?.updateHoveredIndexPath(nil)
    }
    scrollView.documentView = collectionView
  }

  private func setupCategories() {
    for (index, tab) in tabs.enumerated() {
      let button = EmojiPicker2CategoryButton(categoryIndex: index)
      button.toolTip = tab.title
      button.configure(symbol: EmojiPicker2SymbolCache.image(named: tab.symbolName), fallback: tab.fallback)
      button.target = self
      button.action = #selector(categoryButtonPressed(_:))
      categoryBar.contentView.addSubview(button)
      categoryButtons.append(button)
    }
  }

  private func layoutSearchField() {
    let x = EmojiPicker2Layout.searchHorizontalPadding
    let width = max(0, searchBar.contentView.bounds.width - x * 2)
    searchField.frame = NSRect(
      x: x,
      y: floor((searchBar.contentView.bounds.height - EmojiPicker2Layout.searchHeight) / 2),
      width: width,
      height: EmojiPicker2Layout.searchHeight
    )
  }

  private func layoutCategoryButtons() {
    let count = categoryButtons.count
    guard count > 0 else { return }

    let buttonSize = EmojiPicker2Layout.categoryButtonSize
    let spacing = EmojiPicker2Layout.categoryButtonSpacing
    let totalWidth = CGFloat(count) * buttonSize + CGFloat(max(0, count - 1)) * spacing
    let startX = max(
      EmojiPicker2Layout.categoryHorizontalPadding,
      floor((categoryBar.contentView.bounds.width - totalWidth) / 2)
    )
    let y = floor((categoryBar.contentView.bounds.height - buttonSize) / 2)

    for (index, button) in categoryButtons.enumerated() {
      button.frame = NSRect(
        x: startX + CGFloat(index) * (buttonSize + spacing),
        y: y,
        width: buttonSize,
        height: buttonSize
      )
    }
  }

  private func updateCollectionLayoutMetrics() {
    let width = max(1, scrollView.contentView.bounds.width)
    guard abs(width - lastLayoutWidth) > 0.5 else { return }

    lastLayoutWidth = width
    collectionLayout.sectionInset = EmojiPicker2Layout.collectionSectionInset(for: width)
    collectionLayout.headerReferenceSize = NSSize(width: width, height: EmojiPicker2Layout.sectionHeaderHeight)
    collectionLayout.invalidateLayout()
  }

  private func syncDocumentFrame() {
    let clipSize = scrollView.contentView.bounds.size
    guard clipSize.width > 0 else { return }

    let provisionalHeight = max(collectionView.frame.height, clipSize.height)
    let provisionalFrame = NSRect(x: 0, y: 0, width: clipSize.width, height: provisionalHeight)
    if collectionView.frame != provisionalFrame {
      collectionView.frame = provisionalFrame
    }

    collectionView.layoutSubtreeIfNeeded()
    let contentSize = collectionLayout.collectionViewContentSize
    let documentHeight = max(clipSize.height, ceil(contentSize.height))
    let newFrame = NSRect(x: 0, y: 0, width: clipSize.width, height: documentHeight)

    guard collectionView.frame != newFrame else { return }
    collectionView.frame = newFrame
  }

  private func scheduleDocumentFrameSync(resetScroll: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      syncDocumentFrame()
      if resetScroll {
        scrollToTop()
      }
    }
  }

  private func applySections(_ newSections: [EmojiPickerSection], resetScroll: Bool) {
    let preferredSkinTone = AppSettings.shared.preferredEmojiSkinTone
    sections = newSections.map { section in
      EmojiPickerSection(
        id: section.id,
        title: section.title,
        items: section.items.map { $0.applying(skinTone: preferredSkinTone) }
      )
    }
    emptyLabel.isHidden = sections.contains { !$0.items.isEmpty }
    updateHoveredIndexPath(nil)
    collectionLayout.invalidateLayout()
    collectionView.reloadData()
    scheduleDocumentFrameSync(resetScroll: resetScroll)
    preloadImages(for: sections, scale: displayScale)
  }

  private var displayScale: CGFloat {
    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? EmojiPicker2Layout.defaultImageScale
  }

  private func preloadImagesForCurrentScale() {
    let scale = displayScale
    let scaleKey = EmojiPicker2ImageCache.scaleKey(for: scale)
    guard preloadedImageScaleKeys.insert(scaleKey).inserted else { return }

    preloadImages(for: sections, scale: scale)
  }

  private func preloadImages(for sections: [EmojiPickerSection], scale: CGFloat) {
    let emojis = sections.flatMap(\.items).map(\.emoji)
    guard !emojis.isEmpty else { return }

    imageCache.preload(emojis, scale: scale)
  }

  private func scrollToTop() {
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func selectFirstResult() {
    guard let item = sections.first?.items.first else { return }
    delegate?.emojiPicker2RootView(self, didSelect: item.emoji)
  }

  private func setQuery(_ value: String) {
    guard query != value else { return }

    query = value
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      applySections(EmojiPickerData.defaultSections, resetScroll: true)
      return
    }

    let results = EmojiPickerData.suggestions(matching: trimmed, limit: 160)
    applySections(
      results.isEmpty ? [] : [EmojiPickerSection(id: "search", title: "Results", items: results)],
      resetScroll: true
    )
  }

  private func selectCategory(_ index: Int) {
    guard tabs.indices.contains(index) else { return }

    if !query.isEmpty {
      query = ""
      searchField.stringValue = ""
      applySections(EmojiPickerData.defaultSections, resetScroll: false)
    }

    DispatchQueue.main.async { [weak self] in
      self?.scrollToSection(index)
    }
  }

  private func scrollToSection(_ index: Int) {
    guard sections.indices.contains(index), !sections[index].items.isEmpty else { return }

    updateHoveredIndexPath(nil)
    collectionView.scrollToItems(
      at: [IndexPath(item: 0, section: index)],
      scrollPosition: .top
    )
  }

  private func emojiItem(at indexPath: IndexPath) -> EmojiPickerItem? {
    guard sections.indices.contains(indexPath.section),
          sections[indexPath.section].items.indices.contains(indexPath.item)
    else {
      return nil
    }

    return sections[indexPath.section].items[indexPath.item]
  }

  private func updateHoveredIndexPath(_ indexPath: IndexPath?) {
    let validIndexPath = indexPath.flatMap { emojiItem(at: $0) == nil ? nil : $0 }
    guard hoveredIndexPath != validIndexPath else { return }

    let previous = hoveredIndexPath
    hoveredIndexPath = validIndexPath

    if let previous,
       let item = collectionView.item(at: previous) as? EmojiPicker2CollectionItem {
      item.setHovered(false)
    }

    if let validIndexPath,
       let item = collectionView.item(at: validIndexPath) as? EmojiPicker2CollectionItem {
      item.setHovered(true)
    }
  }

  @objc private func searchChanged(_ sender: NSSearchField) {
    setQuery(sender.stringValue)
  }

  @objc private func categoryButtonPressed(_ sender: EmojiPicker2CategoryButton) {
    selectCategory(sender.categoryIndex)
  }
}

extension EmojiPicker2RootView: NSSearchFieldDelegate {
  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
      return false
    }

    selectFirstResult()
    return true
  }
}

extension EmojiPicker2RootView: NSCollectionViewDataSource {
  func numberOfSections(in _: NSCollectionView) -> Int {
    sections.count
  }

  func collectionView(_: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
    guard sections.indices.contains(section) else { return 0 }
    return sections[section].items.count
  }

  func collectionView(
    _ collectionView: NSCollectionView,
    itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    guard let emoji = emojiItem(at: indexPath),
          let item = collectionView.makeItem(
            withIdentifier: EmojiPicker2CollectionItem.identifier,
            for: indexPath
          ) as? EmojiPicker2CollectionItem
    else {
      return NSCollectionViewItem()
    }

    let scale = displayScale
    item.configure(
      with: emoji,
      image: imageCache.image(for: emoji.emoji, scale: scale),
      isHovered: indexPath == hoveredIndexPath,
      displayScale: scale
    )
    return item
  }

  func collectionView(
    _ collectionView: NSCollectionView,
    viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
    at indexPath: IndexPath
  ) -> NSView {
    guard kind == NSCollectionView.elementKindSectionHeader,
          sections.indices.contains(indexPath.section),
          let view = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: EmojiPicker2HeaderView.identifier,
            for: indexPath
          ) as? EmojiPicker2HeaderView
    else {
      return NSView()
    }

    view.configure(title: sections[indexPath.section].title)
    return view
  }
}

extension EmojiPicker2RootView: NSCollectionViewDelegate {
  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard let indexPath = indexPaths.first, let item = emojiItem(at: indexPath) else { return }

    collectionView.deselectItems(at: indexPaths)
    delegate?.emojiPicker2RootView(self, didSelect: item.emoji)
  }
}

extension EmojiPicker2RootView: NSCollectionViewDelegateFlowLayout {
  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    sizeForItemAt _: IndexPath
  ) -> NSSize {
    NSSize(width: EmojiPicker2Layout.itemSize, height: EmojiPicker2Layout.itemSize)
  }

  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    insetForSectionAt _: Int
  ) -> NSEdgeInsets {
    EmojiPicker2Layout.collectionSectionInset(for: max(1, scrollView.contentView.bounds.width))
  }

  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    minimumLineSpacingForSectionAt _: Int
  ) -> CGFloat {
    EmojiPicker2Layout.itemSpacing
  }

  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    minimumInteritemSpacingForSectionAt _: Int
  ) -> CGFloat {
    EmojiPicker2Layout.itemSpacing
  }

  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    referenceSizeForHeaderInSection _: Int
  ) -> NSSize {
    NSSize(width: max(1, scrollView.contentView.bounds.width), height: EmojiPicker2Layout.sectionHeaderHeight)
  }
}

extension EmojiPicker2RootView: EmojiPicker2CollectionViewHoverDelegate {
  func emojiPicker2CollectionView(_ collectionView: EmojiPicker2CollectionView, didHoverAt point: NSPoint?) {
    guard collectionView === self.collectionView, let point else {
      updateHoveredIndexPath(nil)
      return
    }

    updateHoveredIndexPath(collectionView.indexPathForItem(at: point))
  }
}

private final class EmojiPicker2SearchField: NSSearchField {
  override func cancelOperation(_ sender: Any?) {
    stringValue = ""
    sendAction(action, to: target)
  }
}

private final class EmojiPicker2ScrollView: NSScrollView {
  var didScroll: (() -> Void)?

  override func scrollWheel(with event: NSEvent) {
    didScroll?()
    super.scrollWheel(with: event)
  }

  override func reflectScrolledClipView(_ cView: NSClipView) {
    super.reflectScrolledClipView(cView)
    didScroll?()
  }
}

@MainActor
private protocol EmojiPicker2CollectionViewHoverDelegate: AnyObject {
  func emojiPicker2CollectionView(_ collectionView: EmojiPicker2CollectionView, didHoverAt point: NSPoint?)
}

private final class EmojiPicker2CollectionView: NSCollectionView {
  weak var hoverDelegate: EmojiPicker2CollectionViewHoverDelegate?
  private var hoverTrackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }

    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    hoverTrackingArea = trackingArea
    addTrackingArea(trackingArea)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    publishHoverPoint(from: event)
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    publishHoverPoint(from: event)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    hoverDelegate?.emojiPicker2CollectionView(self, didHoverAt: nil)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if window == nil {
      hoverDelegate?.emojiPicker2CollectionView(self, didHoverAt: nil)
    }
  }

  private func publishHoverPoint(from event: NSEvent) {
    hoverDelegate?.emojiPicker2CollectionView(self, didHoverAt: convert(event.locationInWindow, from: nil))
  }
}

private final class EmojiPicker2CollectionItem: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("EmojiPicker2CollectionItem")

  private var cellView: EmojiPicker2CellView? {
    view as? EmojiPicker2CellView
  }

  override func loadView() {
    view = EmojiPicker2CellView(frame: NSRect(
      x: 0,
      y: 0,
      width: EmojiPicker2Layout.itemSize,
      height: EmojiPicker2Layout.itemSize
    ))
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    cellView?.configure(
      emoji: "",
      image: nil,
      accessibilityLabel: nil,
      toolTip: nil,
      isHovered: false,
      displayScale: EmojiPicker2Layout.defaultImageScale
    )
  }

  func configure(
    with item: EmojiPickerItem,
    image: CGImage?,
    isHovered: Bool,
    displayScale: CGFloat
  ) {
    let hint = ":\(item.shortcode):"
    cellView?.configure(
      emoji: item.emoji,
      image: image,
      accessibilityLabel: "\(item.label), \(hint)",
      toolTip: hint,
      isHovered: isHovered,
      displayScale: displayScale
    )
  }

  func setHovered(_ isHovered: Bool) {
    cellView?.setHovered(isHovered)
  }
}

private final class EmojiPicker2CellView: NSView {
  private let imageLayer = CALayer()
  private var emoji = ""
  private var hasImage = false
  private var isHovering = false

  override var isFlipped: Bool {
    true
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if window == nil {
      setHovered(false)
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackground()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard !emoji.isEmpty, !hasImage else { return }

    let font = EmojiPicker2Layout.emojiFont
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    let rect = NSRect(
      x: 0,
      y: floor((bounds.height - lineHeight) / 2) + EmojiPicker2Layout.emojiBaselineAdjustment,
      width: bounds.width,
      height: lineHeight
    )

    emoji.draw(
      with: rect,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: EmojiPicker2Layout.emojiAttributes,
      context: nil
    )
  }

  func configure(
    emoji: String,
    image: CGImage?,
    accessibilityLabel: String?,
    toolTip: String?,
    isHovered: Bool,
    displayScale: CGFloat
  ) {
    if self.emoji != emoji {
      self.emoji = emoji
      needsDisplay = true
    }
    updateImage(image, displayScale: displayScale)
    setAccessibilityLabel(accessibilityLabel)
    self.toolTip = toolTip
    setHovered(isHovered)
  }

  func updateImage(_ image: CGImage?, displayScale: CGFloat) {
    let nextHasImage = image != nil
    if hasImage != nextHasImage {
      hasImage = nextHasImage
      needsDisplay = true
    }

    CATransaction.withoutEmojiPicker2Actions {
      imageLayer.contentsScale = displayScale
      imageLayer.contents = image
      imageLayer.isHidden = image == nil
    }
  }

  func setHovered(_ isHovered: Bool) {
    guard isHovering != isHovered else { return }

    isHovering = isHovered
    updateBackground()
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = EmojiPicker2Layout.itemCornerRadius
    setAccessibilityRole(.button)

    imageLayer.contentsGravity = .resizeAspect
    imageLayer.contentsScale = EmojiPicker2Layout.defaultImageScale
    imageLayer.isHidden = true
    imageLayer.actions = [
      "contents": NSNull(),
      "bounds": NSNull(),
      "position": NSNull(),
      "hidden": NSNull(),
    ]
    layer?.addSublayer(imageLayer)

    updateBackground()
  }

  override func layout() {
    super.layout()

    let size = EmojiPicker2Layout.emojiImageSize
    CATransaction.withoutEmojiPicker2Actions {
      imageLayer.frame = CGRect(
        x: floor((bounds.width - size) / 2),
        y: floor((bounds.height - size) / 2),
        width: size,
        height: size
      )
    }
  }

  private func updateBackground() {
    let color = isHovering
      ? NSColor.labelColor.resolvedColor(with: effectiveAppearance).withAlphaComponent(0.08)
      : NSColor.clear
    layer?.backgroundColor = color.cgColor
  }
}

private extension CATransaction {
  static func withoutEmojiPicker2Actions(_ work: () -> Void) {
    begin()
    setDisableActions(true)
    work()
    commit()
  }
}

private final class EmojiPicker2HeaderView: NSView {
  static let identifier = NSUserInterfaceItemIdentifier("EmojiPicker2HeaderView")

  private let label = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    label.frame = NSRect(
      x: EmojiPicker2Layout.sectionHeaderHorizontalInset,
      y: 5,
      width: max(0, bounds.width - EmojiPicker2Layout.sectionHeaderHorizontalInset * 2),
      height: max(0, bounds.height - 8)
    )
  }

  func configure(title: String) {
    label.stringValue = title
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)
  }
}

private enum EmojiPicker2SeparatorEdge {
  case top
  case bottom
}

private final class EmojiPicker2BarView: NSView {
  let contentView = NSView()
  private let separatorEdge: EmojiPicker2SeparatorEdge
  private let separatorView = NSView()

  init(separatorEdge: EmojiPicker2SeparatorEdge) {
    self.separatorEdge = separatorEdge
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    contentView.frame = bounds

    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let separatorHeight = 1 / scale
    switch separatorEdge {
    case .top:
      separatorView.frame = NSRect(x: 0, y: bounds.height - separatorHeight, width: bounds.width, height: separatorHeight)
    case .bottom:
      separatorView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: separatorHeight)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateSeparatorColor()
    needsLayout = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateSeparatorColor()
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    addSubview(contentView)
    separatorView.wantsLayer = true
    addSubview(separatorView)
    updateSeparatorColor()
  }

  private func updateSeparatorColor() {
    separatorView.layer?.backgroundColor = NSColor.separatorColor
      .resolvedColor(with: effectiveAppearance)
      .withAlphaComponent(0.08)
      .cgColor
  }
}

private final class EmojiPicker2CategoryButton: NSButton {
  let categoryIndex: Int

  init(categoryIndex: Int) {
    self.categoryIndex = categoryIndex
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(symbol: NSImage?, fallback: String) {
    image = symbol
    title = symbol == nil ? fallback : ""
    alternateTitle = ""
    imagePosition = symbol == nil ? .noImage : .imageOnly
  }

  private func setupView() {
    bezelStyle = .rounded
    setButtonType(.momentaryPushIn)
    imagePosition = .imageOnly
    imageScaling = .scaleProportionallyDown
    isBordered = false
    showsBorderOnlyWhileMouseInside = true
    focusRingType = .none
    setAccessibilityRole(.button)
    contentTintColor = .secondaryLabelColor
  }
}

private struct EmojiPicker2CategoryTab: Hashable {
  let sectionID: String
  let title: String
  let symbolName: String
  let fallback: String

  static func makeTabs(from sections: [EmojiPickerSection]) -> [EmojiPicker2CategoryTab] {
    sections.map { section in
      EmojiPicker2CategoryTab(
        sectionID: section.id,
        title: section.title,
        symbolName: symbolName(for: section.id),
        fallback: fallback(for: section.id)
      )
    }
  }

  private static func symbolName(for id: String) -> String {
    switch id {
    case "smileys": return "face.smiling"
    case "people": return "hand.raised"
    case "animals": return "leaf"
    case "food": return "fork.knife"
    case "travel": return "airplane"
    case "activities": return "party.popper"
    case "objects": return "shippingbox"
    case "symbols": return "number"
    case "flags": return "flag"
    default: return "circle"
    }
  }

  private static func fallback(for id: String) -> String {
    switch id {
    case "smileys": return ":)"
    case "people": return "hand"
    case "animals": return "leaf"
    case "food": return "food"
    case "travel": return "fly"
    case "activities": return "play"
    case "objects": return "box"
    case "symbols": return "#"
    case "flags": return "flag"
    default: return "."
    }
  }
}

@MainActor
private enum EmojiPicker2SymbolCache {
  private static var images: [String: NSImage] = [:]

  static func image(named name: String) -> NSImage? {
    if let image = images[name] {
      return image
    }

    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    image?.isTemplate = true
    images[name] = image
    return image
  }
}

private final class EmojiPicker2ImageCache: @unchecked Sendable {
  static let shared = EmojiPicker2ImageCache()

  private struct CacheKey: Hashable {
    let emoji: String
    let scale: Int

    init(emoji: String, scale: CGFloat) {
      self.emoji = emoji
      self.scale = EmojiPicker2ImageCache.scaleKey(for: scale)
    }

    var displayScale: CGFloat {
      CGFloat(scale) / 100
    }
  }

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "chat.inline.emoji-picker2.image-cache", qos: .utility)
  private var images: [CacheKey: CGImage] = [:]
  private var pending = Set<CacheKey>()

  static func scaleKey(for scale: CGFloat) -> Int {
    Int((max(1, scale) * 100).rounded())
  }

  func image(for emoji: String, scale: CGFloat) -> CGImage? {
    cachedImage(for: CacheKey(emoji: emoji, scale: scale))
  }

  func preload(_ emojis: [String], scale: CGFloat) {
    let missing = reserveMissing(emojis.map { CacheKey(emoji: $0, scale: scale) })
    guard !missing.isEmpty else { return }

    queue.async { [weak self] in
      guard let self else { return }
      for key in missing {
        autoreleasepool {
          guard let image = Self.render(key.emoji, scale: key.displayScale) else {
            self.finishPending(key)
            return
          }
          self.store(image, for: key)
        }
      }
    }
  }

  private func cachedImage(for key: CacheKey) -> CGImage? {
    lock.lock()
    defer { lock.unlock() }
    return images[key]
  }

  private func reserveMissing(_ keys: [CacheKey]) -> [CacheKey] {
    lock.lock()
    defer { lock.unlock() }

    var seen = Set<CacheKey>()
    var missing: [CacheKey] = []
    for key in keys where seen.insert(key).inserted && images[key] == nil && !pending.contains(key) {
      pending.insert(key)
      missing.append(key)
    }
    return missing
  }

  private func store(_ image: CGImage, for key: CacheKey) {
    lock.lock()
    images[key] = image
    pending.remove(key)
    lock.unlock()
  }

  private func finishPending(_ key: CacheKey) {
    lock.lock()
    pending.remove(key)
    lock.unlock()
  }

  private static func render(_ emoji: String, scale: CGFloat) -> CGImage? {
    let pointSize = EmojiPicker2Layout.emojiImageSize
    let pixelSize = Int(ceil(pointSize * scale))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: pixelSize,
      height: pixelSize,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }

    context.scaleBy(x: scale, y: scale)
    context.textMatrix = .identity

    let font = CTFontCreateWithName(
      "AppleColorEmoji" as CFString,
      EmojiPicker2Layout.emojiFontSize,
      nil
    )
    let attrs: [NSAttributedString.Key: Any] = [
      kCTFontAttributeName as NSAttributedString.Key: font,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: attrs))
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let lineHeight = ascent + descent
    let x = floor((pointSize - width) / 2)
    let baseline = floor((pointSize - lineHeight) / 2 + descent)

    context.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, context)
    return context.makeImage()
  }
}

private enum EmojiPicker2Layout {
  static let width: CGFloat = 320
  static let height: CGFloat = 380
  static let searchHeight: CGFloat = 24
  static let searchBarHeight: CGFloat = 42
  static let searchHorizontalPadding: CGFloat = 14
  static let categoryBarHeight: CGFloat = 38
  static let categoryHorizontalPadding: CGFloat = 10
  static let categoryButtonSize: CGFloat = 26
  static let categoryButtonSpacing: CGFloat = 6
  static let itemSize: CGFloat = 34
  static let itemSpacing: CGFloat = 7
  static let itemCornerRadius: CGFloat = 7
  static let emojiImageSize: CGFloat = 30
  static let defaultImageScale: CGFloat = 2
  static let emojiFontSize: CGFloat = 25
  static let sectionHeaderHeight: CGFloat = 31
  static let sectionHeaderHorizontalInset: CGFloat = 18
  static let preferredColumnCount = 7
  static let minCollectionHorizontalInset: CGFloat = 17
  static let collectionTopInset: CGFloat = 7
  static let collectionBottomInset: CGFloat = 16
  static let emojiBaselineAdjustment: CGFloat = -1
  static var emojiFont: NSFont {
    NSFont(name: "AppleColorEmoji", size: emojiFontSize) ?? .systemFont(ofSize: emojiFontSize)
  }
  static var emojiAttributes: [NSAttributedString.Key: Any] {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    paragraphStyle.lineBreakMode = .byClipping

    return [
      .font: emojiFont,
      .paragraphStyle: paragraphStyle,
    ]
  }

  static func columnCount(for width: CGFloat) -> Int {
    let availableWidth = max(1, width - minCollectionHorizontalInset * 2)
    let stride = itemSize + itemSpacing
    let fittedColumns = Int((availableWidth + itemSpacing) / stride)
    return max(1, min(preferredColumnCount, fittedColumns))
  }

  static func collectionSectionInset(for width: CGFloat) -> NSEdgeInsets {
    let columns = columnCount(for: width)
    let rowWidth = CGFloat(columns) * itemSize + CGFloat(max(0, columns - 1)) * itemSpacing
    let horizontalInset = max(minCollectionHorizontalInset, floor((width - rowWidth) / 2))

    return NSEdgeInsets(
      top: collectionTopInset,
      left: horizontalInset,
      bottom: collectionBottomInset,
      right: horizontalInset
    )
  }
}
