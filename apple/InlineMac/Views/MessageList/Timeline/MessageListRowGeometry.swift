import AppKit

/// Where a message list's rows are, for the gestures that select across them (text selection across messages,
/// message selection by dragging, keys while selecting). Rows are indices into the list's rows
/// (`ChatRowListViewModel.rows`), the same for the table list (one table row per list row) and the timeline list.
/// Points are in `rowsView`'s coordinates unless the name says window.
@MainActor
protocol MessageListRowGeometry: AnyObject {
  /// The view the rows are laid out in.
  var rowsView: NSView { get }
  /// The view that takes first responder while text or messages are selected, so Copy, Escape and the selection keys
  /// reach the list.
  var keyView: NSView { get }
  var numberOfRows: Int { get }
  /// The row under a point; nil between rows or past them.
  func row(at point: NSPoint) -> Int?
  /// The row under a point at the rows' middle; past the first or last row it has, that row (a drag past an end);
  /// nil in a gap between rows.
  func clampedRow(at point: NSPoint) -> Int?
  /// The row a view inside the list belongs to.
  func row(containing view: NSView) -> Int?
  /// The message cell showing a row, when the row is placed.
  func cell(atRow row: Int) -> MessageTableCell?
  /// Rows that have a view now (on screen and in the margins), in order.
  var placedRows: [Int] { get }
  /// The view a press at a window point lands on, when it lands on the rows (not on a bar or button above them).
  func hit(atWindowPoint point: NSPoint) -> NSView?
  /// A list background under a press (between and beside bubbles), where a drag selects whole messages.
  func isRowBackground(_ view: NSView) -> Bool
  /// Whether a first responder belongs to the list.
  func ownsResponder(_ view: NSView) -> Bool
  /// The area showing rows in window coordinates: inside the toolbar and composer when `insetsOnly`, else the
  /// list's whole frame.
  func autoscrollRegion(insetsOnly: Bool) -> NSRect?
  /// Scrolls the rows by a pointer distance past an edge in window coordinates (negative: below the bottom edge, so
  /// later rows come in). False at an end.
  @discardableResult func autoscroll(by step: CGFloat) -> Bool
  func scrollRowToVisible(_ row: Int)
}

/// The table list's rows: its NSTableView in its scroll view, as the selection controllers used them directly.
@MainActor
final class TableRowGeometry: MessageListRowGeometry {
  private weak var table: NSTableView?

  init(table: NSTableView) {
    self.table = table
  }

  var rowsView: NSView { table ?? NSView() }
  var keyView: NSView { rowsView }
  var numberOfRows: Int { table?.numberOfRows ?? 0 }

  func row(at point: NSPoint) -> Int? {
    guard let table else { return nil }
    let row = table.row(at: point)
    return row >= 0 ? row : nil
  }

  func clampedRow(at point: NSPoint) -> Int? {
    guard let table, table.numberOfRows > 0 else { return nil }
    let row = table.row(at: NSPoint(x: table.bounds.midX, y: point.y))
    if row >= 0 { return row }
    if point.y < table.bounds.minY { return table.isFlipped ? 0 : table.numberOfRows - 1 }
    if point.y > table.bounds.maxY { return table.isFlipped ? table.numberOfRows - 1 : 0 }
    return nil
  }

  func row(containing view: NSView) -> Int? {
    guard let table else { return nil }
    let row = table.row(for: view)
    return row >= 0 ? row : nil
  }

  func cell(atRow row: Int) -> MessageTableCell? {
    guard let table, row >= 0, row < table.numberOfRows else { return nil }
    return table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell
  }

  var placedRows: [Int] {
    guard let table else { return [] }
    let visible = table.rows(in: table.visibleRect)
    guard visible.location != NSNotFound else { return [] }
    return Array(visible.location ..< min(NSMaxRange(visible), table.numberOfRows))
  }

  func hit(atWindowPoint point: NSPoint) -> NSView? {
    guard let table, let scrollView = table.enclosingScrollView, !scrollView.isHiddenOrHasHiddenAncestor,
          scrollView.bounds.contains(scrollView.convert(point, from: nil)),
          let hit = scrollView.hitTest(scrollView.superview?.convert(point, from: nil) ?? point),
          hit === table || hit.isDescendant(of: table)
    else { return nil }
    return hit
  }

  func isRowBackground(_ view: NSView) -> Bool {
    view is NSTableView || view is NSTableRowView
  }

  func ownsResponder(_ view: NSView) -> Bool {
    guard let table else { return false }
    return view === table || view.isDescendant(of: table)
  }

  func autoscrollRegion(insetsOnly: Bool) -> NSRect? {
    guard let scrollView = table?.enclosingScrollView else { return nil }
    guard insetsOnly else { return scrollView.convert(scrollView.bounds, to: nil) }
    let insets = scrollView.contentInsets
    var rect = scrollView.bounds
    rect.origin.x += insets.left
    rect.size.width -= insets.left + insets.right
    rect.size.height -= insets.top + insets.bottom
    if !scrollView.isFlipped { rect.origin.y += insets.bottom } else { rect.origin.y += insets.top }
    guard rect.height > 32 else { return scrollView.convert(scrollView.bounds, to: nil) }
    return scrollView.convert(rect, to: nil)
  }

  @discardableResult
  func autoscroll(by step: CGFloat) -> Bool {
    guard let scrollView = table?.enclosingScrollView else { return false }
    let clip = scrollView.contentView
    var proposed = clip.bounds
    proposed.origin.y += clip.isFlipped ? -step : step
    // The clip view knows the list's content insets; it clamps to the scrollable range.
    let origin = clip.constrainBoundsRect(proposed).origin
    guard origin.y != clip.bounds.origin.y else { return false }
    clip.scroll(to: origin)
    scrollView.reflectScrolledClipView(clip)
    return true
  }

  func scrollRowToVisible(_ row: Int) {
    table?.scrollRowToVisible(row)
  }
}
