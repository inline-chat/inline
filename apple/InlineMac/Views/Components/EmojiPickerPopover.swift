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

  var body: some View {
    EmojiPickerAppKitView(onSelect: onSelect)
      .frame(width: EmojiPickerLayout.width, height: EmojiPickerLayout.height)
  }
}

private struct EmojiPickerAppKitView: NSViewRepresentable {
  var onSelect: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onSelect: onSelect)
  }

  func makeNSView(context: Context) -> EmojiPickerRootView {
    let view = EmojiPickerRootView()
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

@MainActor
private protocol EmojiPickerRootViewDelegate: AnyObject {
  func emojiPickerRootView(_ view: EmojiPickerRootView, didSelect emoji: String)
}

@MainActor
private final class EmojiPickerRootView: NSView {
  weak var delegate: EmojiPickerRootViewDelegate?

  private let effectView = NSVisualEffectView()
  private let searchField = EmojiPickerSearchField()
  private let topDivider = NSBox()
  private let scrollView = NSScrollView()
  private let collectionView = NSCollectionView()
  private let collectionLayout = NSCollectionViewFlowLayout()
  private let emptyLabel = NSTextField(labelWithString: "No emoji found")
  private let bottomDivider = NSBox()
  private let categoryScrollView = NSScrollView()
  private let categoryStack = NSStackView()

	  private var sections = EmojiPickerData.defaultSections
	  private var query = ""
	  private var sectionOffsets: [CGFloat] = []
	  private var focusedSearchOnAttach = false

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

  override func layout() {
    super.layout()
    rebuildSectionOffsets()
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    effectView.material = .popover
    effectView.blendingMode = .withinWindow
    effectView.state = .active
    effectView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(effectView)

    searchField.placeholderString = "Search emoji"
    searchField.controlSize = .regular
    searchField.font = .systemFont(ofSize: 13)
    searchField.focusRingType = .default
    searchField.sendsSearchStringImmediately = true
    searchField.sendsWholeSearchString = false
    searchField.delegate = self
    searchField.target = self
    searchField.action = #selector(searchChanged(_:))
    searchField.translatesAutoresizingMaskIntoConstraints = false
    addSubview(searchField)

    topDivider.boxType = .separator
    topDivider.translatesAutoresizingMaskIntoConstraints = false
    addSubview(topDivider)

    scrollView.drawsBackground = false
    scrollView.contentView.drawsBackground = false
    scrollView.contentView.backgroundColor = .clear
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = true
    scrollView.scrollerStyle = .overlay
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

    emptyLabel.font = .systemFont(ofSize: 12)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(emptyLabel)

    bottomDivider.boxType = .separator
    bottomDivider.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bottomDivider)

    categoryScrollView.drawsBackground = false
    categoryScrollView.contentView.drawsBackground = false
    categoryScrollView.contentView.backgroundColor = .clear
    categoryScrollView.hasVerticalScroller = false
    categoryScrollView.hasHorizontalScroller = false
    categoryScrollView.scrollerStyle = .overlay
    categoryScrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(categoryScrollView)

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

      searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: EmojiPickerLayout.searchHorizontalPadding),
      searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -EmojiPickerLayout.searchHorizontalPadding),
      searchField.topAnchor.constraint(equalTo: topAnchor, constant: EmojiPickerLayout.searchVerticalPadding),
      searchField.heightAnchor.constraint(equalToConstant: EmojiPickerLayout.searchHeight),

      topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
      topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
      topDivider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: EmojiPickerLayout.searchVerticalPadding),
      topDivider.heightAnchor.constraint(equalToConstant: 1),

      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),

      emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

      bottomDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
      bottomDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomDivider.bottomAnchor.constraint(equalTo: categoryScrollView.topAnchor),
      bottomDivider.heightAnchor.constraint(equalToConstant: 1),

      categoryScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      categoryScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      categoryScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      categoryScrollView.heightAnchor.constraint(equalToConstant: EmojiPickerLayout.categoryBarHeight),

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
    collectionLayout.sectionInset = EmojiPickerLayout.collectionSectionInset
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
  }

  private func setupCategories() {
    for (index, tab) in tabs.enumerated() {
      let button = EmojiPickerCategoryButton(categoryIndex: index)
      button.toolTip = tab.title
      button.image = EmojiPickerSymbolCache.image(named: tab.symbolName)
      button.title = tab.fallback
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
    let width = max(collectionView.bounds.width, EmojiPickerLayout.width)
    let inset = EmojiPickerLayout.collectionSectionInset
    let availableWidth = max(1, width - inset.left - inset.right)
    let stride = EmojiPickerLayout.itemSize + EmojiPickerLayout.itemSpacing
    let columns = max(1, Int((availableWidth + EmojiPickerLayout.itemSpacing) / stride))

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
    EmojiPickerLayout.collectionSectionInset
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
    NSSize(width: EmojiPickerLayout.width, height: EmojiPickerLayout.sectionHeaderHeight)
  }
}

private final class EmojiPickerSearchField: NSSearchField {
  override func cancelOperation(_ sender: Any?) {
    stringValue = ""
    sendAction(action, to: target)
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
    cellView?.configure(image: nil, toolTip: nil)
  }

  func configure(with item: EmojiPickerItem, image: CGImage?) {
    let hint = ":\(item.shortcode):"
    cellView?.configure(image: image, toolTip: hint)
  }
}

private final class EmojiPickerCellView: NSView {
  private let imageLayer = CALayer()

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

  func configure(image: CGImage?, toolTip: String?) {
    CATransaction.withoutActions {
      imageLayer.contents = image
    }
    self.toolTip = toolTip
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.cornerRadius = EmojiPickerLayout.itemCornerRadius

    imageLayer.contentsGravity = .resizeAspect
    imageLayer.contentsScale = EmojiPickerLayout.imageScale
    imageLayer.actions = [
      "contents": NSNull(),
      "bounds": NSNull(),
      "position": NSNull(),
    ]
    layer?.addSublayer(imageLayer)
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

    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: EmojiPickerLayout.sectionHeaderHorizontalInset),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -EmojiPickerLayout.sectionHeaderHorizontalInset),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
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

  private func setupView() {
    bezelStyle = .rounded
    setButtonType(.momentaryPushIn)
    imagePosition = .imageOnly
    imageScaling = .scaleProportionallyDown
    isBordered = false
    showsBorderOnlyWhileMouseInside = true
    focusRingType = .none
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
  static let width: CGFloat = 306
  static let height: CGFloat = 318
  static let searchHeight: CGFloat = 28
  static let searchHorizontalPadding: CGFloat = 10
  static let searchVerticalPadding: CGFloat = 7
  static let categoryBarHeight: CGFloat = 34
  static let categoryHorizontalPadding: CGFloat = 10
  static let categoryButtonSize: CGFloat = 26
  static let categoryButtonSpacing: CGFloat = 4
  static let itemSize: CGFloat = 30
  static let itemSpacing: CGFloat = 3
  static let itemCornerRadius: CGFloat = 7
  static let emojiImageSize: CGFloat = 24
  static let imageScale: CGFloat = 2
  static let sectionHeaderHeight: CGFloat = 24
  static let sectionHeaderHorizontalInset: CGFloat = 12
  static let emojiFontSize: CGFloat = 22
  static let emojiFont = CTFontCreateWithName(
    "AppleColorEmoji" as CFString,
    emojiFontSize,
    nil
  )
  static let collectionSectionInset = NSEdgeInsets(
    top: 4,
    left: 9,
    bottom: 12,
    right: 9
  )
}
