import AppKit
import TimelineAppKit
import TimelineCore

/// The timeline list's rows for the selection gestures. Rows are indices into the shell's rows; the engine keys its
/// views by row id and places only rows near the screen, so a row far away has no view (as an offscreen table row
/// has none).
@MainActor
final class TimelineRowGeometry: MessageListRowGeometry {
  typealias Row = ChatRowListViewModel.Row

  private weak var list: TimelineListView<Row>?
  private let rows: () -> [Row]
  private let index: (Row) -> Int?
  /// Covered at the top (toolbar, pinned header, a bar under the toolbar) and the bottom (composer).
  private let insets: () -> (top: CGFloat, bottom: CGFloat)
  private let responder = TimelineSelectionKeyView()

  init(
    list: TimelineListView<Row>, rows: @escaping () -> [Row], index: @escaping (Row) -> Int?,
    insets: @escaping () -> (top: CGFloat, bottom: CGFloat)
  ) {
    self.list = list
    self.rows = rows
    self.index = index
    self.insets = insets
  }

  /// What Copy does, and whether it can, while the key view is first responder.
  var onCopy: (() -> Bool)? {
    get { responder.onCopy }
    set { responder.onCopy = newValue }
  }

  var canCopy: (() -> Bool)? {
    get { responder.canCopy }
    set { responder.canCopy = newValue }
  }

  var rowsView: NSView { list ?? NSView() }

  /// Beside the list in its superview, so it is in the window from the first selection on.
  var keyView: NSView {
    if responder.superview == nil, let list, let superview = list.superview {
      superview.addSubview(responder, positioned: .below, relativeTo: list)
    }
    return responder
  }

  var numberOfRows: Int { rows().count }

  func row(at point: NSPoint) -> Int? {
    list?.row(atPresented: point).flatMap(index)
  }

  func clampedRow(at point: NSPoint) -> Int? {
    guard let list else { return nil }
    if let row = row(at: NSPoint(x: list.bounds.midX, y: point.y)) { return row }
    // Placed rows, top to bottom as presented: past the first or last, that row; in a gap, nothing.
    let placed = list.placedViews.compactMap { id, view -> (Row, CGRect)? in
      list.presentedFrame(of: view).map { (id, $0) }
    }.sorted { $0.1.minY < $1.1.minY }
    guard let first = placed.first, let last = placed.last else { return nil }
    if point.y < first.1.minY { return index(first.0) }
    if point.y >= last.1.maxY { return index(last.0) }
    return nil
  }

  func row(containing view: NSView) -> Int? {
    guard let list else { return nil }
    for (id, rowView) in list.placedViews where view === rowView || view.isDescendant(of: rowView) {
      return index(id)
    }
    return nil
  }

  func cell(atRow row: Int) -> MessageTableCell? {
    let rows = rows()
    guard let list, rows.indices.contains(row) else { return nil }
    return (list.view(for: rows[row]) as? TimelineRowHost)?.content as? MessageTableCell
  }

  var placedRows: [Int] {
    guard let list else { return [] }
    return list.placedViews.compactMap { index($0.0) }.sorted()
  }

  func hit(atWindowPoint point: NSPoint) -> NSView? {
    // Through the list's superview, so a bar, button or header above the rows takes its own presses.
    guard let list, !list.isHiddenOrHasHiddenAncestor, let root = list.superview,
          list.bounds.contains(list.convert(point, from: nil)),
          let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point),
          hit === list || hit.isDescendant(of: list)
    else { return nil }
    return hit
  }

  func isRowBackground(_ view: NSView) -> Bool {
    guard let list else { return false }
    return view === list || view === list.content || view is TimelineRowHost
  }

  func ownsResponder(_ view: NSView) -> Bool {
    guard let list else { return false }
    return view === responder || view === list || view.isDescendant(of: list)
  }

  func autoscrollRegion(insetsOnly: Bool) -> NSRect? {
    guard let list else { return nil }
    var rect = list.bounds
    if insetsOnly {
      let insets = insets()
      // Flipped: the top inset is at the small y.
      rect.origin.y += insets.top
      rect.size.height -= insets.top + insets.bottom
      if rect.height <= 32 { rect = list.bounds }
    }
    return list.convert(rect, to: nil)
  }

  @discardableResult
  func autoscroll(by step: CGFloat) -> Bool {
    guard let list else { return false }
    let before = list.timelineLayout.placements.first.map { ($0.id, $0.y) }
    // Positive steps (the pointer above the top edge) move the content down, bringing earlier rows in.
    list.apply(TimelineTransaction(scroll: .by(step)))
    let after = list.timelineLayout.placements.first.map { ($0.id, $0.y) }
    return before?.0 != after?.0 || before?.1 != after?.1
  }

  func scrollRowToVisible(_ row: Int) {
    let rows = rows()
    guard let list, rows.indices.contains(row) else { return }
    let id = rows[row]
    let insets = insets()
    let usable = (top: insets.top, bottom: list.bounds.height - insets.bottom)
    if let frame = list.frame(for: id), frame.minY >= usable.top, frame.maxY <= usable.bottom { return }
    let above = list.frame(for: id).map { $0.minY < usable.top }
      ?? (rows.firstIndex(of: list.timelineLayout.visible.first?.id ?? id).map { row < $0 } ?? true)
    list.apply(TimelineTransaction(scroll: .to(id, above ? .top(0) : .bottom(0)), timing: .standard))
  }
}

/// The timeline list's first responder while its text or messages are selected: Copy (Edit menu, Cmd-C) and the keys
/// reach the selection through it. It draws nothing and takes no clicks.
final class TimelineSelectionKeyView: NSView, NSMenuItemValidation {
  var onCopy: (() -> Bool)?
  var canCopy: (() -> Bool)?

  override var acceptsFirstResponder: Bool { true }
  override func hitTest(_: NSPoint) -> NSView? { nil }

  @objc func copy(_: Any?) {
    if onCopy?() != true { NSSound.beep() }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(copy(_:)) { return canCopy?() ?? false }
    return true
  }
}
