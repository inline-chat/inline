import AppKit
import Combine
import InlineKit
import InlineUI
import Logger
import SwiftUI

protocol MentionCompletionMenuDelegate: AnyObject {
  func mentionMenu(_ menu: MentionCompletionMenu, didSelectUser user: UserInfo, withText text: String, userId: Int64)
  func mentionMenuDidRequestClose(_ menu: MentionCompletionMenu)
}

class MentionCompletionMenu: NSView {
  weak var delegate: MentionCompletionMenuDelegate?

  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let backgroundView = NSVisualEffectView()
  private let log = Log.scoped("MentionCompletionMenu")
  private let model = MentionCompletionViewModel()

  private(set) var isVisible: Bool = false

  private var heightConstraint: NSLayoutConstraint!
  private var filteredParticipants: [UserInfo] {
    model.items
  }

  private var selectedIndex: Int {
    model.selectedIndex
  }

  var hasItems: Bool {
    model.isVisible
  }

  // Extract size constants
  public enum Layout {
    static let maxHeight: CGFloat = 144
    static let rowHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 0
    static let avatarSize: CGFloat = 28
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 2
    static let avatarNameSpacing: CGFloat = 8
    static let nameUsernameSpacing: CGFloat = 0
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool {
    // Don't steal focus from compose view
    false
  }

  private func setupView() {
    wantsLayer = true

    // Background with vibrancy
    backgroundView.material = .popover
    backgroundView.blendingMode = .withinWindow
    backgroundView.state = .active
    backgroundView.wantsLayer = true
    backgroundView.layer?.cornerRadius = Layout.cornerRadius
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)

    // Scroll view setup
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.borderType = .noBorder
    scrollView.wantsLayer = true
    scrollView.layer?.cornerRadius = Layout.cornerRadius
    scrollView.layer?.masksToBounds = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    // Remove all content insets
    scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    // Table view setup
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.style = .plain
    tableView.allowsEmptySelection = false
    tableView.delegate = self
    tableView.dataSource = self
    tableView.target = self
    tableView.action = #selector(tableViewClicked)
    // Disable native selection highlighting since we're doing custom selection styling
    tableView.focusRingType = .none
    tableView.selectionHighlightStyle = .none

    // Remove intercell spacing to prevent unwanted gaps
    tableView.intercellSpacing = NSSize(width: 0, height: 0)

    // Create column
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("participant"))
    column.width = 300
    tableView.addTableColumn(column)

    scrollView.documentView = tableView

    // Configure table view to not steal focus
    tableView.refusesFirstResponder = true

    addSubview(scrollView)

    // Layout constraints - removed fixed width constraint
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

    // Initially hidden
    alphaValue = 0
    isHidden = true
  }

  func updateParticipants(_ participants: [UserInfo]) {
    log.trace("MentionMenu updateParticipants: received \(participants.count) participants")
    model.updateParticipants(participants)
    updateTableViewAndHeight()
  }

  func updateCandidates(_ candidates: [MentionCompletionUser]) {
    log.trace("MentionMenu updateCandidates: received \(candidates.count) candidates")
    model.updateCandidates(candidates)
    updateTableViewAndHeight()
  }

  func filterParticipants(with query: String) {
    log.trace("MentionMenu filterParticipants: query='\(query)', total participants=\(filteredParticipants.count)")
    model.filter(with: query)
    log.trace("MentionMenu filterParticipants: filtered to \(filteredParticipants.count) participants")
    updateTableViewAndHeight()
  }

  private func updateTableViewAndHeight() {
    let itemCount = filteredParticipants.count

    tableView.reloadData()

    guard itemCount > 0 else {
      heightConstraint.constant = 0
      hide(animated: false)
      return
    }

    // Simplified height calculation - just row height * item count
    let contentHeight = CGFloat(itemCount) * Layout.rowHeight

    // Apply max height limit
    let newHeight = min(contentHeight, Layout.maxHeight)

    log
      .debug(
        "🔍 MentionMenu updateTableViewAndHeight: itemCount=\(itemCount), contentHeight=\(contentHeight), finalHeight=\(newHeight)"
      )

    // Animate height change
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = ModernTimingFunctions.snappy
      heightConstraint.animator().constant = newHeight
    }

    // Update selection if needed
    if selectedIndex < itemCount {
      let indexSet = IndexSet(integer: selectedIndex)
      tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
      tableView.scrollRowToVisible(selectedIndex)
    }
  }

  func show(animated: Bool = true) {
    guard hasItems else {
      hide(animated: false)
      return
    }

    guard !isVisible else {
      log.trace("MentionMenu show: already visible")
      return
    }

    log.trace("MentionMenu show: showing menu with \(filteredParticipants.count) participants")
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

    log.trace("MentionMenu show: menu should now be visible, alphaValue=\(alphaValue), isHidden=\(isHidden)")
  }

  func hide(animated: Bool = true) {
    guard isVisible else { return }
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
    guard !filteredParticipants.isEmpty else { return }
    model.selectNext()
    updateSelection()
  }

  func selectPrevious() {
    guard !filteredParticipants.isEmpty else { return }
    model.selectPrevious()
    updateSelection()
  }

  private func updateSelection() {
    let indexSet = IndexSet(integer: selectedIndex)
    tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
    tableView.scrollRowToVisible(selectedIndex)

    // Update custom selection styling for all visible cells
    updateCellSelectionStates()
  }

  private func updateCellSelectionStates() {
    // Update selection state for all visible rows
    for row in 0 ..< filteredParticipants.count {
      if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MentionTableCellView {
        cellView.isSelected = (row == selectedIndex)
      }
    }
  }

  /// Selects the current item and returns true if successful, false otherwise
  @discardableResult
  func selectCurrentItem() -> Bool {
    guard let participant = model.selectedItem else { return false }
    let mentionText = model.mentionText(for: participant)
    delegate?.mentionMenu(self, didSelectUser: participant, withText: mentionText, userId: participant.user.id)
    return true
  }

  @objc private func tableViewClicked() {
    // Get the clicked row
    let clickedRow = tableView.clickedRow
    if clickedRow >= 0, clickedRow < filteredParticipants.count {
      model.select(index: clickedRow)

      // Don't let the table view steal focus - we want compose to keep focus
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // Trigger selection without stealing focus
        selectCurrentItem()
      }
    }
  }

  @objc private func tableViewDoubleClicked() {
    selectCurrentItem()
  }
}

// MARK: - NSTableViewDataSource

extension MentionCompletionMenu: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    filteredParticipants.count
  }
}

// MARK: - NSTableViewDelegate

extension MentionCompletionMenu: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("MentionCell")

    var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? MentionTableCellView
    if cellView == nil {
      cellView = MentionTableCellView()
      cellView?.identifier = identifier
    }

    if row < filteredParticipants.count {
      let participant = filteredParticipants[row]
      cellView?.configure(with: participant)
      // Set selection state
      cellView?.isSelected = (row == selectedIndex)
    }

    return cellView
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    Layout.rowHeight
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    model.select(index: row)
    // Update selection styling immediately
    updateCellSelectionStates()
    return true
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    if tableView.selectedRow >= 0 {
      model.select(index: tableView.selectedRow)
      // Update selection styling when selection changes
      updateCellSelectionStates()
    }
  }
}

enum ModernTimingFunctions {
  // Snappy spring-like
  static let snappy = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)

  // Bouncy entrance
  static let bouncy = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.275)

  // Smooth and responsive
  static let smooth = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)

  // Quick and decisive
  static let decisive = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
}
