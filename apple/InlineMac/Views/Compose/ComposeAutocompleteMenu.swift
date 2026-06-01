import AppKit
import InlineKit

protocol ComposeAutocompleteMenuDelegate: AnyObject {
  func autocompleteMenu(_ menu: ComposeAutocompleteMenu, didSelect item: ComposeAutocompleteItem)
  func autocompleteMenuDidRequestClose(_ menu: ComposeAutocompleteMenu)
}

final class ComposeAutocompleteMenu: NSView {
  weak var delegate: ComposeAutocompleteMenuDelegate?

  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let backgroundView = NSVisualEffectView()

  private var items: [ComposeAutocompleteItem] = []
  private var selectedIndex = 0
  private(set) var isVisible = false
  private var heightConstraint: NSLayoutConstraint!

  enum Layout {
    static let maxHeight: CGFloat = 184
    static let rowHeight: CGFloat = 40
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

  func update(items: [ComposeAutocompleteItem], selectedIndex: Int) {
    self.items = items
    self.selectedIndex = items.indices.contains(selectedIndex) ? selectedIndex : 0
    updateTableViewAndHeight()
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

    backgroundView.material = .popover
    backgroundView.blendingMode = .withinWindow
    backgroundView.state = .active
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)

    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.borderType = .noBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false

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
    column.width = 340
    tableView.addTableColumn(column)

    scrollView.documentView = tableView
    addSubview(scrollView)

    heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      heightConstraint,
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    alphaValue = 0
    isHidden = true
  }

  private func updateTableViewAndHeight() {
    let contentHeight = CGFloat(items.count) * Layout.rowHeight
    let newHeight = min(contentHeight, Layout.maxHeight)

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = ModernTimingFunctions.snappy
      heightConstraint.animator().constant = newHeight
    }

    tableView.reloadData()
    updateSelection()
  }

  private func updateSelection() {
    guard !items.isEmpty else { return }
    tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    tableView.scrollRowToVisible(selectedIndex)

    for row in 0 ..< items.count {
      if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ComposeAutocompleteMenuItem {
        cellView.isSelected = row == selectedIndex
      }
    }
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
