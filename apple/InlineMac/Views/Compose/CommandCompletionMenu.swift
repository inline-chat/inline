import AppKit
import InlineKit

protocol CommandCompletionMenuDelegate: AnyObject {
  func commandMenu(
    _ menu: CommandCompletionMenu,
    didSelectSuggestion suggestion: ComposeCommandSuggestion,
    sendAfterInsertion: Bool
  )
  func commandMenuDidRequestClose(_ menu: CommandCompletionMenu)
}

final class CommandCompletionMenu: ComposeCompletionMenuView {
  weak var delegate: CommandCompletionMenuDelegate?

  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let surfaceView: ComposeCompletionSurfaceView

  private var suggestions: [ComposeCommandSuggestion] = []
  private var selectedIndex = 0
  var isVisible: Bool { isPresented }
  private var heightConstraint: NSLayoutConstraint!

  enum Layout {
    static let maxHeight: CGFloat = 184
    static let rowHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 16
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

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = Layout.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOffset = NSSize(width: 0, height: -6)
    layer?.shadowRadius = 14
    layer?.shadowOpacity = 0.12
    layer?.masksToBounds = false
    addSubview(surfaceView)

    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
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

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
    column.width = 340
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    scrollView.documentView = tableView
    addSubview(scrollView)

    heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      heightConstraint,
      surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
      surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
      surfaceView.topAnchor.constraint(equalTo: topAnchor),
      surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  override func layout() {
    super.layout()
    if bounds.width > 1 {
      tableView.tableColumns.first?.width = bounds.width
    }
    layer?.shadowPath = CGPath(
      roundedRect: bounds,
      cornerWidth: Layout.cornerRadius,
      cornerHeight: Layout.cornerRadius,
      transform: nil
    )
  }

  func updateSuggestions(_ suggestions: [ComposeCommandSuggestion]) {
    self.suggestions = suggestions
    selectedIndex = 0
    updateTableViewAndHeight()
  }

  func show(animated: Bool = true) {
    guard !suggestions.isEmpty else {
      hide(animated: false)
      return
    }

    present(animated: animated)
  }

  func hide(animated: Bool = true) {
    dismiss(animated: animated)
  }

  func selectNext() {
    guard !suggestions.isEmpty else { return }
    selectedIndex = (selectedIndex + 1) % suggestions.count
    updateSelection()
  }

  func selectPrevious() {
    guard !suggestions.isEmpty else { return }
    selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : suggestions.count - 1
    updateSelection()
  }

  @discardableResult
  func selectCurrentItem(sendAfterInsertion: Bool = true) -> Bool {
    guard selectedIndex >= 0, selectedIndex < suggestions.count else { return false }
    delegate?.commandMenu(
      self,
      didSelectSuggestion: suggestions[selectedIndex],
      sendAfterInsertion: sendAfterInsertion
    )
    return true
  }

  private func updateTableViewAndHeight() {
    let contentHeight = CGFloat(suggestions.count) * Layout.rowHeight
    let newHeight = min(contentHeight, Layout.maxHeight)

    setHeight(newHeight, constraint: heightConstraint)

    tableView.reloadData()
    updateSelection()
  }

  private func updateSelection() {
    guard !suggestions.isEmpty else { return }
    tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    tableView.scrollRowToVisible(selectedIndex)

    for row in 0 ..< suggestions.count {
      if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CommandCompletionMenuItem {
        cellView.isSelected = row == selectedIndex
      }
    }
  }

  @objc private func tableViewClicked() {
    let clickedRow = tableView.clickedRow
    guard clickedRow >= 0, clickedRow < suggestions.count else { return }
    selectedIndex = clickedRow
    DispatchQueue.main.async { [weak self] in
      _ = self?.selectCurrentItem()
    }
  }
}

extension CommandCompletionMenu: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    suggestions.count
  }
}

extension CommandCompletionMenu: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("CommandCell")
    let cellView = (tableView.makeView(withIdentifier: identifier, owner: self) as? CommandCompletionMenuItem) ?? {
      let view = CommandCompletionMenuItem()
      view.identifier = identifier
      return view
    }()

    if row < suggestions.count {
      cellView.configure(with: suggestions[row])
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
