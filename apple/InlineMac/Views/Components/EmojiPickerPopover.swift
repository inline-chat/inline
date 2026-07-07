import AppKit
import CoreText
import InlineKit
import QuartzCore
import SwiftUI
import TextProcessing

enum EmojiPickerValue {
  static func normalizedEmoji(from text: String) -> String? {
    let placeholder = "\u{FFFC}"
    let cleaned = text
      .replacingOccurrences(of: placeholder, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let emoji = cleaned.first(where: \.isEmoji) else { return nil }
    return String(emoji)
  }
}

struct EmojiPickerPopover: View {
  var onSelect: (String) -> Void

  static var preferredContentSize: NSSize {
    NSSize(width: EmojiPickerLayout.width, height: EmojiPickerLayout.height)
  }

  var body: some View {
    EmojiPickerAppKitView(onSelect: onSelect)
      .frame(width: Self.preferredContentSize.width, height: Self.preferredContentSize.height)
      .fixedSize()
  }

  @MainActor
  static func makeViewController(onSelect: @escaping (String) -> Void) -> NSViewController {
    EmojiPickerPopoverViewController(onSelect: onSelect)
  }

  @MainActor
  static func makePopover(onSelect: @escaping (String) -> Void) -> NSPopover {
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    if #available(macOS 14.0, *) {
      popover.hasFullSizeContent = true
    }
    popover.contentSize = preferredContentSize
    popover.contentViewController = makeViewController { [weak popover] emoji in
      onSelect(emoji)
      popover?.performClose(nil)
    }
    return popover
  }
}

struct EmojiPickerPopoverPresenter: NSViewRepresentable {
  @Binding var isPresented: Bool
  var preferredEdge: NSRectEdge = .maxY
  var onSelect: (String) -> Void
  var onDismiss: () -> Void = {}

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context _: Context) -> EmojiPickerPopoverAnchorView {
    EmojiPickerPopoverAnchorView()
  }

  func updateNSView(_ view: EmojiPickerPopoverAnchorView, context: Context) {
    context.coordinator.update(configuration: self, anchorView: view)
  }

  static func dismantleNSView(_ nsView: EmojiPickerPopoverAnchorView, coordinator: Coordinator) {
    coordinator.closePopover(sendDismiss: false)
  }

  @MainActor
  final class Coordinator: NSObject, NSPopoverDelegate {
    private var configuration: EmojiPickerPopoverPresenter?
    private weak var anchorView: NSView?
    private var popover: NSPopover?
    private var isPresentationDeferred = false

    func update(configuration: EmojiPickerPopoverPresenter, anchorView: NSView) {
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

      let popover = EmojiPickerPopover.makePopover { [weak self] emoji in
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

final class EmojiPickerPopoverAnchorView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

private struct EmojiPickerAppKitView: NSViewRepresentable {
  var onSelect: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onSelect: onSelect)
  }

  func makeNSView(context: Context) -> EmojiPickerRootView {
    let view = EmojiPickerRootView(frame: NSRect(origin: .zero, size: EmojiPickerPopover.preferredContentSize))
    view.delegate = context.coordinator
    return view
  }

  func updateNSView(_ view: EmojiPickerRootView, context: Context) {
    context.coordinator.onSelect = onSelect
    view.delegate = context.coordinator
  }

  final class Coordinator: NSObject, EmojiPickerRootViewDelegate {
    var onSelect: (String) -> Void

    init(onSelect: @escaping (String) -> Void) {
      self.onSelect = onSelect
    }

    func emojiPickerRootView(_: EmojiPickerRootView, didSelect emoji: String) {
      onSelect(emoji)
    }
  }
}

private final class EmojiPickerPopoverViewController: NSViewController, EmojiPickerRootViewDelegate {
  private var onSelect: (String) -> Void

  init(onSelect: @escaping (String) -> Void) {
    self.onSelect = onSelect
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = EmojiPickerPopover.preferredContentSize
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let view = EmojiPickerRootView(frame: NSRect(origin: .zero, size: EmojiPickerPopover.preferredContentSize))
    view.delegate = self
    self.view = view
  }

  func emojiPickerRootView(_: EmojiPickerRootView, didSelect emoji: String) {
    onSelect(emoji)
  }
}

@MainActor
private protocol EmojiPickerRootViewDelegate: AnyObject {
  func emojiPickerRootView(_ view: EmojiPickerRootView, didSelect emoji: String)
}

@MainActor
private final class EmojiPickerRootView: NSView {
  weak var delegate: EmojiPickerRootViewDelegate?

  private let effectView = NSVisualEffectView()
  private let searchBarView = EmojiPickerAccessoryBarView(separatorEdge: .bottom)
  private let searchField = EmojiPickerSearchField()
  private let scrollView = NSScrollView()
  private let collectionView = NSCollectionView()
  private let collectionLayout = NSCollectionViewFlowLayout()
  private let emptyLabel = NSTextField(labelWithString: "No emoji found")
  private let categoryBarView = EmojiPickerAccessoryBarView(separatorEdge: .top)
  private let categoryScrollView = NSScrollView()
  private let categoryStack = NSStackView()

  private var sections = EmojiPickerData.defaultSections
  private var query = ""
  private var sectionOffsets: [CGFloat] = []
  private var focusedSearchOnAttach = false
  private var lastCollectionLayoutWidth: CGFloat = 0

  private let tabs = EmojiPickerCategoryTab.makeTabs(from: EmojiPickerData.defaultSections)
  private let imageCache = EmojiPickerImageCache.shared

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
    setupCollectionView()
    setupCategories()
    applySections(EmojiPickerData.defaultSections, resetScroll: true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    guard window != nil, !focusedSearchOnAttach else { return }
    focusedSearchOnAttach = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      window?.makeFirstResponder(searchField)
    }
  }

  override var intrinsicContentSize: NSSize {
    EmojiPickerPopover.preferredContentSize
  }

  override func layout() {
    super.layout()
    updateCollectionLayoutMetrics()
    rebuildSectionOffsets()
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    setContentHuggingPriority(.required, for: .horizontal)
    setContentHuggingPriority(.required, for: .vertical)
    setContentCompressionResistancePriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .vertical)

    effectView.material = .popover
    effectView.blendingMode = .withinWindow
    effectView.state = .active
    effectView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(effectView)

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
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

    emptyLabel.font = .systemFont(ofSize: 12)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(emptyLabel)

    searchBarView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(searchBarView)

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
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchBarView.contentView.addSubview(searchField)

    categoryBarView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(categoryBarView)

    categoryScrollView.drawsBackground = false
    categoryScrollView.contentView.drawsBackground = false
    categoryScrollView.contentView.backgroundColor = .clear
    categoryScrollView.hasVerticalScroller = false
    categoryScrollView.hasHorizontalScroller = false
    categoryScrollView.scrollerStyle = .overlay
    categoryScrollView.translatesAutoresizingMaskIntoConstraints = false
    categoryBarView.contentView.addSubview(categoryScrollView)

    categoryStack.orientation = .horizontal
    categoryStack.alignment = .centerY
    categoryStack.distribution = .gravityAreas
    categoryStack.spacing = EmojiPickerLayout.categoryButtonSpacing
    categoryStack.edgeInsets = NSEdgeInsets(
      top: 0,
      left: EmojiPickerLayout.categoryHorizontalPadding,
      bottom: 0,
      right: EmojiPickerLayout.categoryHorizontalPadding
    )
    categoryStack.translatesAutoresizingMaskIntoConstraints = false
    categoryScrollView.documentView = categoryStack

    NSLayoutConstraint.activate([
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: searchBarView.bottomAnchor),
      scrollView.bottomAnchor.constraint(equalTo: categoryBarView.topAnchor),

      emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

      searchBarView.leadingAnchor.constraint(equalTo: leadingAnchor),
      searchBarView.trailingAnchor.constraint(equalTo: trailingAnchor),
      searchBarView.topAnchor.constraint(equalTo: topAnchor),
      searchBarView.bottomAnchor.constraint(
        equalTo: safeAreaLayoutGuide.topAnchor,
        constant: EmojiPickerLayout.searchBarHeight
      ),

      searchField.leadingAnchor.constraint(
        equalTo: safeAreaLayoutGuide.leadingAnchor,
        constant: EmojiPickerLayout.searchHorizontalPadding
      ),
      searchField.trailingAnchor.constraint(
        equalTo: safeAreaLayoutGuide.trailingAnchor,
        constant: -EmojiPickerLayout.searchHorizontalPadding
      ),
      searchField.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: EmojiPickerLayout.searchVerticalPadding),
      searchField.heightAnchor.constraint(equalToConstant: EmojiPickerLayout.searchHeight),

      categoryBarView.leadingAnchor.constraint(equalTo: leadingAnchor),
      categoryBarView.trailingAnchor.constraint(equalTo: trailingAnchor),
      categoryBarView.topAnchor.constraint(
        equalTo: safeAreaLayoutGuide.bottomAnchor,
        constant: -EmojiPickerLayout.categoryBarHeight
      ),
      categoryBarView.bottomAnchor.constraint(equalTo: bottomAnchor),

      categoryScrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      categoryScrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      categoryScrollView.topAnchor.constraint(
        equalTo: safeAreaLayoutGuide.bottomAnchor,
        constant: -EmojiPickerLayout.categoryBarHeight
      ),
      categoryScrollView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

      categoryStack.leadingAnchor.constraint(equalTo: categoryScrollView.contentView.leadingAnchor),
      categoryStack.trailingAnchor.constraint(equalTo: categoryScrollView.contentView.trailingAnchor),
      categoryStack.topAnchor.constraint(equalTo: categoryScrollView.contentView.topAnchor),
      categoryStack.bottomAnchor.constraint(equalTo: categoryScrollView.contentView.bottomAnchor),
      categoryStack.heightAnchor.constraint(equalTo: categoryScrollView.contentView.heightAnchor),
    ])
  }

  private func setupCollectionView() {
    collectionLayout.scrollDirection = .vertical
    collectionLayout.itemSize = NSSize(width: EmojiPickerLayout.itemSize, height: EmojiPickerLayout.itemSize)
    collectionLayout.minimumInteritemSpacing = EmojiPickerLayout.itemSpacing
    collectionLayout.minimumLineSpacing = EmojiPickerLayout.itemSpacing
    collectionLayout.sectionInset = EmojiPickerLayout.collectionSectionInset(for: EmojiPickerLayout.width)
    collectionLayout.headerReferenceSize = NSSize(width: EmojiPickerLayout.width, height: EmojiPickerLayout.sectionHeaderHeight)

    collectionView.collectionViewLayout = collectionLayout
    collectionView.backgroundColors = [.clear]
    collectionView.wantsLayer = true
    collectionView.layer?.backgroundColor = NSColor.clear.cgColor
    collectionView.isSelectable = true
    collectionView.allowsMultipleSelection = false
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.register(
      EmojiPickerCollectionItem.self,
      forItemWithIdentifier: EmojiPickerCollectionItem.identifier
    )
    collectionView.register(
      EmojiPickerHeaderView.self,
      forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
      withIdentifier: EmojiPickerHeaderView.identifier
    )

    scrollView.documentView = collectionView

    let widthConstraint = collectionView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
    widthConstraint.priority = .required
    widthConstraint.isActive = true
    updateCollectionLayoutMetrics()
  }

  private func setupCategories() {
    for (index, tab) in tabs.enumerated() {
      let button = EmojiPickerCategoryButton(categoryIndex: index)
      button.toolTip = tab.title
      button.configure(symbol: EmojiPickerSymbolCache.image(named: tab.symbolName), fallback: tab.fallback)
      button.target = self
      button.action = #selector(categoryButtonPressed(_:))
      button.translatesAutoresizingMaskIntoConstraints = false

      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: EmojiPickerLayout.categoryButtonSize),
        button.heightAnchor.constraint(equalToConstant: EmojiPickerLayout.categoryButtonSize),
      ])

      categoryStack.addArrangedSubview(button)
    }
  }

  private func applySections(_ newSections: [EmojiPickerSection], resetScroll: Bool) {
    sections = newSections
    emptyLabel.isHidden = sections.contains { !$0.items.isEmpty }
    collectionLayout.invalidateLayout()
    collectionView.reloadData()
    rebuildSectionOffsets()
    warmImages(for: sections)

    guard resetScroll else { return }
    scrollToTop()
  }

  private func warmImages(for sections: [EmojiPickerSection]) {
    imageCache.warm(sections.flatMap(\.items)) { [weak self] emojis in
      Task { @MainActor in
        self?.reloadVisibleImages(matching: emojis)
      }
    }
  }

  private func reloadVisibleImages(matching emojis: Set<String>) {
    guard !emojis.isEmpty else { return }

    let visibleIndexPaths = collectionView.indexPathsForVisibleItems().filter { indexPath in
      guard sections.indices.contains(indexPath.section),
            sections[indexPath.section].items.indices.contains(indexPath.item)
      else {
        return false
      }

      return emojis.contains(sections[indexPath.section].items[indexPath.item].emoji)
    }

    guard !visibleIndexPaths.isEmpty else { return }
    collectionView.reloadItems(at: Set(visibleIndexPaths))
  }

  private func scrollToTop() {
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func selectFirstResult() {
    guard let item = sections.first?.items.first else { return }
    delegate?.emojiPickerRootView(self, didSelect: item.emoji)
  }

  private func setQuery(_ value: String) {
    guard query != value else { return }

    query = value
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      applySections(EmojiPickerData.defaultSections, resetScroll: true)
      return
    }

    let results = EmojiPickerData.suggestions(matching: trimmed, limit: 120)
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

    scrollToSection(index)
  }

  private func scrollToSection(_ index: Int) {
    rebuildSectionOffsets()
    guard sectionOffsets.indices.contains(index) else { return }

    let maxY = max(0, collectionView.bounds.height - scrollView.contentView.bounds.height)
    let y = min(max(0, sectionOffsets[index]), maxY)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func rebuildSectionOffsets() {
    let width = max(collectionView.bounds.width, scrollView.contentView.bounds.width, EmojiPickerLayout.width)
    let inset = EmojiPickerLayout.collectionSectionInset(for: width)
    let columns = EmojiPickerLayout.columnCount(for: width)

    var y: CGFloat = 0
    sectionOffsets = sections.map { section in
      let sectionY = y
      let rowCount = section.items.isEmpty ? 0 : Int(ceil(Double(section.items.count) / Double(columns)))
      let itemsHeight = CGFloat(rowCount) * EmojiPickerLayout.itemSize +
        CGFloat(max(0, rowCount - 1)) * EmojiPickerLayout.itemSpacing
      y += EmojiPickerLayout.sectionHeaderHeight + inset.top + itemsHeight + inset.bottom
      return sectionY
    }
  }

  @objc private func searchChanged(_ sender: NSSearchField) {
    setQuery(sender.stringValue)
  }

  @objc private func categoryButtonPressed(_ sender: EmojiPickerCategoryButton) {
    selectCategory(sender.categoryIndex)
  }

  private func updateCollectionLayoutMetrics() {
    let width = max(scrollView.contentView.bounds.width, EmojiPickerLayout.width)
    guard abs(width - lastCollectionLayoutWidth) > 0.5 else { return }

    lastCollectionLayoutWidth = width
    collectionLayout.sectionInset = EmojiPickerLayout.collectionSectionInset(for: width)
    collectionLayout.headerReferenceSize = NSSize(width: width, height: EmojiPickerLayout.sectionHeaderHeight)
    collectionLayout.invalidateLayout()
  }
}

extension EmojiPickerRootView: NSSearchFieldDelegate {
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

extension EmojiPickerRootView: NSCollectionViewDataSource {
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
    guard sections.indices.contains(indexPath.section),
          sections[indexPath.section].items.indices.contains(indexPath.item),
          let item = collectionView.makeItem(
            withIdentifier: EmojiPickerCollectionItem.identifier,
            for: indexPath
          ) as? EmojiPickerCollectionItem
    else {
      return NSCollectionViewItem()
    }

    let emoji = sections[indexPath.section].items[indexPath.item]
    item.configure(with: emoji, image: imageCache.image(for: emoji.emoji))
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
            withIdentifier: EmojiPickerHeaderView.identifier,
            for: indexPath
          ) as? EmojiPickerHeaderView
    else {
      return NSView()
    }

    view.configure(title: sections[indexPath.section].title)
    return view
  }
}

extension EmojiPickerRootView: NSCollectionViewDelegate {
  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard let indexPath = indexPaths.first,
          sections.indices.contains(indexPath.section),
          sections[indexPath.section].items.indices.contains(indexPath.item)
    else {
      return
    }

    collectionView.deselectItems(at: indexPaths)
    let item = sections[indexPath.section].items[indexPath.item]
    delegate?.emojiPickerRootView(self, didSelect: item.emoji)
  }
}

extension EmojiPickerRootView: NSCollectionViewDelegateFlowLayout {
  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    sizeForItemAt _: IndexPath
  ) -> NSSize {
    NSSize(width: EmojiPickerLayout.itemSize, height: EmojiPickerLayout.itemSize)
  }

  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    insetForSectionAt _: Int
  ) -> NSEdgeInsets {
    EmojiPickerLayout.collectionSectionInset(for: max(collectionView.bounds.width, EmojiPickerLayout.width))
  }

  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    minimumLineSpacingForSectionAt _: Int
  ) -> CGFloat {
    EmojiPickerLayout.itemSpacing
  }

  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    minimumInteritemSpacingForSectionAt _: Int
  ) -> CGFloat {
    EmojiPickerLayout.itemSpacing
  }

  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    referenceSizeForHeaderInSection _: Int
  ) -> NSSize {
    NSSize(
      width: max(collectionView.bounds.width, EmojiPickerLayout.width),
      height: EmojiPickerLayout.sectionHeaderHeight
    )
  }
}

private final class EmojiPickerSearchField: NSSearchField {
  override func cancelOperation(_ sender: Any?) {
    stringValue = ""
    sendAction(action, to: target)
  }
}

private enum EmojiPickerSeparatorEdge {
  case top
  case bottom
  case none
}

private final class EmojiPickerAccessoryBarView: NSView {
  let contentView = NSView()
  private let separatorEdge: EmojiPickerSeparatorEdge
  private let separatorView = NSView()
  private var separatorHeightConstraint: NSLayoutConstraint?

  init(separatorEdge: EmojiPickerSeparatorEdge) {
    self.separatorEdge = separatorEdge
    super.init(frame: .zero)
    setupView()
  }

  override init(frame frameRect: NSRect) {
    separatorEdge = .bottom
    super.init(frame: frameRect)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    contentView.translatesAutoresizingMaskIntoConstraints = false

    if #available(macOS 26.0, *) {
      let glassView = NSGlassEffectView()
      glassView.translatesAutoresizingMaskIntoConstraints = false
      glassView.cornerRadius = 0
      glassView.style = .clear
      glassView.contentView = contentView
      addSubview(glassView)
      pin(glassView, in: self)
      pinEmbeddedContentView(contentView, fallbackSuperview: glassView)
    } else {
      let materialView = NSVisualEffectView()
      materialView.material = .popover
      materialView.blendingMode = .withinWindow
      materialView.state = .active
      materialView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(materialView)
      addSubview(contentView)
      pin(materialView, in: self)
      pin(contentView, in: self)
    }

    setupSeparator()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateSeparatorHeight()
    updateSeparatorColor()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateSeparatorColor()
  }

  private func pin(_ view: NSView, in parent: NSView) {
    if view.superview == nil {
      parent.addSubview(view)
    }

    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
      view.topAnchor.constraint(equalTo: parent.topAnchor),
      view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
  }

  private func pinEmbeddedContentView(_ contentView: NSView, fallbackSuperview: NSView) {
    if contentView.superview == nil {
      fallbackSuperview.addSubview(contentView)
    }

    guard let superview = contentView.superview else { return }
    NSLayoutConstraint.activate([
      contentView.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: superview.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: superview.bottomAnchor),
    ])
  }

  private func setupSeparator() {
    guard separatorEdge != .none else { return }

    separatorView.translatesAutoresizingMaskIntoConstraints = false
    separatorView.wantsLayer = true
    addSubview(separatorView)

    let heightConstraint = separatorView.heightAnchor.constraint(equalToConstant: 1)
    separatorHeightConstraint = heightConstraint

    let edgeConstraint: NSLayoutConstraint
    switch separatorEdge {
    case .top:
      edgeConstraint = separatorView.topAnchor.constraint(equalTo: topAnchor)
    case .bottom:
      edgeConstraint = separatorView.bottomAnchor.constraint(equalTo: bottomAnchor)
    case .none:
      edgeConstraint = separatorView.bottomAnchor.constraint(equalTo: bottomAnchor)
    }

    NSLayoutConstraint.activate([
      separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
      separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
      edgeConstraint,
      heightConstraint,
    ])

    updateSeparatorHeight()
    updateSeparatorColor()
  }

  private func updateSeparatorHeight() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    separatorHeightConstraint?.constant = 1 / scale
  }

  private func updateSeparatorColor() {
    let appearance = effectiveAppearance
    separatorView.layer?.backgroundColor = NSColor.separatorColor
      .resolvedColor(with: appearance)
      .withAlphaComponent(0.04)
      .cgColor
  }
}

private final class EmojiPickerCollectionItem: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("EmojiPickerCollectionItem")

  private var cellView: EmojiPickerCellView? {
    view as? EmojiPickerCellView
  }

  override func loadView() {
    view = EmojiPickerCellView(frame: NSRect(
      x: 0,
      y: 0,
      width: EmojiPickerLayout.itemSize,
      height: EmojiPickerLayout.itemSize
    ))
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    cellView?.configure(image: nil, accessibilityLabel: nil, toolTip: nil)
    cellView?.resetHover()
  }

  func configure(with item: EmojiPickerItem, image: CGImage?) {
    let hint = ":\(item.shortcode):"
    cellView?.configure(image: image, accessibilityLabel: "\(item.label), \(hint)", toolTip: hint)
  }
}

private final class EmojiPickerCellView: NSView {
  private let imageLayer = CALayer()
  private var trackingArea: NSTrackingArea?
  private var isHovering = false

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
    let size = EmojiPickerLayout.emojiImageSize
    CATransaction.withoutActions {
      imageLayer.frame = CGRect(
        x: floor((bounds.width - size) / 2),
        y: floor((bounds.height - size) / 2),
        width: size,
        height: size
      )
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let trackingArea {
      removeTrackingArea(trackingArea)
    }

    let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
    self.trackingArea = trackingArea
    addTrackingArea(trackingArea)
  }

  override func mouseEntered(with event: NSEvent) {
    isHovering = true
    updateBackground()
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
    updateBackground()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackground()
  }

  func configure(image: CGImage?, accessibilityLabel: String?, toolTip: String?) {
    CATransaction.withoutActions {
      imageLayer.contents = image
    }
    setAccessibilityLabel(accessibilityLabel)
    self.toolTip = toolTip
  }

  func resetHover() {
    isHovering = false
    updateBackground()
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = EmojiPickerLayout.itemCornerRadius
    setAccessibilityRole(.button)
    updateBackground()

    imageLayer.contentsGravity = .resizeAspect
    imageLayer.contentsScale = EmojiPickerLayout.imageScale
    imageLayer.actions = [
      "contents": NSNull(),
      "bounds": NSNull(),
      "position": NSNull(),
    ]
    layer?.addSublayer(imageLayer)
  }

  private func updateBackground() {
    let color = isHovering
      ? NSColor.labelColor.resolvedColor(with: effectiveAppearance).withAlphaComponent(0.08)
      : NSColor.clear
    layer?.backgroundColor = color.cgColor
  }
}

private extension CATransaction {
  static func withoutActions(_ work: () -> Void) {
    begin()
    setDisableActions(true)
    work()
    commit()
  }
}

private final class EmojiPickerHeaderView: NSView {
  static let identifier = NSUserInterfaceItemIdentifier("EmojiPickerHeaderView")

  private let label = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(title: String) {
    label.stringValue = title
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: EmojiPickerLayout.sectionHeaderHorizontalInset),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -EmojiPickerLayout.sectionHeaderHorizontalInset),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ])
  }
}

private final class EmojiPickerCategoryButton: NSButton {
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

private struct EmojiPickerCategoryTab: Hashable {
  let sectionID: String
  let title: String
  let symbolName: String
  let fallback: String

  static func makeTabs(from sections: [EmojiPickerSection]) -> [EmojiPickerCategoryTab] {
    sections.map { section in
      EmojiPickerCategoryTab(
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
    case "people": return "✋"
    case "animals": return "◦"
    case "food": return "⌘"
    case "travel": return "↗"
    case "activities": return "★"
    case "objects": return "□"
    case "symbols": return "#"
    case "flags": return "⚑"
    default: return "•"
    }
  }
}

private enum EmojiPickerSymbolCache {
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

private final class EmojiPickerImageCache {
  static let shared = EmojiPickerImageCache()

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "chat.inline.emoji-picker.image-cache", qos: .userInitiated)
  private var images: [String: CGImage] = [:]
  private var pending = Set<String>()

  func image(for emoji: String) -> CGImage? {
    cachedImage(for: emoji)
  }

  func warm(_ items: [EmojiPickerItem], onUpdate: ((Set<String>) -> Void)? = nil) {
    let missing = reserveMissing(items.map(\.emoji))
    guard !missing.isEmpty else { return }

    queue.async { [weak self] in
      guard let self else { return }
      var ready = Set<String>()

      for emoji in missing {
        autoreleasepool {
          guard let image = Self.render(emoji) else {
            self.finishPending(emoji)
            return
          }

          self.store(image, for: emoji)
          guard onUpdate != nil else { return }
          ready.insert(emoji)
          if ready.count >= 48 {
            self.publish(&ready, onUpdate: onUpdate)
          }
        }
      }

      self.publish(&ready, onUpdate: onUpdate)
    }
  }

  private func cachedImage(for emoji: String) -> CGImage? {
    lock.lock()
    defer { lock.unlock() }
    return images[emoji]
  }

  private func reserveMissing(_ emojis: [String]) -> [String] {
    lock.lock()
    defer { lock.unlock() }

    var seen = Set<String>()
    var missing: [String] = []
    for emoji in emojis where seen.insert(emoji).inserted && images[emoji] == nil && !pending.contains(emoji) {
      pending.insert(emoji)
      missing.append(emoji)
    }
    return missing
  }

  private func store(_ image: CGImage, for emoji: String) {
    lock.lock()
    images[emoji] = image
    pending.remove(emoji)
    lock.unlock()
  }

  private func finishPending(_ emoji: String) {
    lock.lock()
    pending.remove(emoji)
    lock.unlock()
  }

  private func publish(_ ready: inout Set<String>, onUpdate: ((Set<String>) -> Void)?) {
    guard !ready.isEmpty, let onUpdate else {
      ready.removeAll()
      return
    }

    let batch = ready
    ready.removeAll()
    DispatchQueue.main.async {
      onUpdate(batch)
    }
  }

  private static func render(_ emoji: String) -> CGImage? {
    let scale = EmojiPickerLayout.imageScale
    let pointSize = EmojiPickerLayout.emojiImageSize
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

    let attrs: [NSAttributedString.Key: Any] = [
      kCTFontAttributeName as NSAttributedString.Key: EmojiPickerLayout.emojiFont,
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

private enum EmojiPickerLayout {
  static let width: CGFloat = 304
  static let height: CGFloat = 348
  static let searchHeight: CGFloat = 24
  static let searchBarHeight: CGFloat = 36
  static let searchHorizontalPadding: CGFloat = 8
  static let searchVerticalPadding: CGFloat = 6
  static let categoryBarHeight: CGFloat = 32
  static let categoryHorizontalPadding: CGFloat = 10
  static let categoryButtonSize: CGFloat = 24
  static let categoryButtonSpacing: CGFloat = 4
  static let itemSize: CGFloat = 31
  static let itemSpacing: CGFloat = 6
  static let itemCornerRadius: CGFloat = 7
  static let emojiImageSize: CGFloat = 25
  static let imageScale: CGFloat = 2
  static let sectionHeaderHeight: CGFloat = 30
  static let sectionHeaderHorizontalInset: CGFloat = 22
  static let preferredColumnCount = 7
  static let minCollectionHorizontalInset: CGFloat = 22
  static let collectionTopInset: CGFloat = 8
  static let collectionBottomInset: CGFloat = 18
  static let emojiFontSize: CGFloat = 23
  static let emojiFont = CTFontCreateWithName(
    "AppleColorEmoji" as CFString,
    emojiFontSize,
    nil
  )

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
