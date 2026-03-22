import AppKit
import InlineKit

protocol CommandCompletionMenuDelegate: AnyObject {
  func commandMenu(_ menu: CommandCompletionMenu, didSelectSuggestion suggestion: PeerBotCommandSuggestion)
  func commandMenuDidRequestClose(_ menu: CommandCompletionMenu)
}

final class CommandCompletionMenu: NSView {
  weak var delegate: CommandCompletionMenuDelegate?

  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let backgroundView = NSVisualEffectView()

  private var suggestions: [PeerBotCommandSuggestion] = []
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

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
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

  func updateSuggestions(_ suggestions: [PeerBotCommandSuggestion]) {
    self.suggestions = suggestions
    selectedIndex = 0
    updateTableViewAndHeight()
  }

  func show(animated: Bool = true) {
    guard !suggestions.isEmpty else {
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
  func selectCurrentItem() -> Bool {
    guard selectedIndex >= 0, selectedIndex < suggestions.count else { return false }
    delegate?.commandMenu(self, didSelectSuggestion: suggestions[selectedIndex])
    return true
  }

  private func updateTableViewAndHeight() {
    let contentHeight = CGFloat(suggestions.count) * Layout.rowHeight
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
