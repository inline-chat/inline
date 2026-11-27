import AppKit
import InlineKit
import TextProcessing
import WebKit

/// A message's selectable text views in reading order, plus what copy needs between them
/// (list markers, rendered math sources, table structure) and what each view shows.
struct MessageTextSelectionProjection {
  let textViews: [any MessageTextSurface]
  let document: [RichTextMultiSurfaceSelection.DocumentItem]
  let literals: [NSAttributedString]
  var roles: [MessageClipboardDocument.SurfaceRole] = []
  var literalRoles: [MessageClipboardDocument.LiteralRole] = []

  static func single(_ textView: any MessageTextSurface) -> MessageTextSelectionProjection {
    MessageTextSelectionProjection(
      textViews: [textView],
      document: [.init(content: .surface(0), separatorAfter: "")],
      literals: [],
      roles: [.body]
    )
  }

  @MainActor var lengths: [Int] { textViews.map { $0.surfaceText.length } }

  /// The selected content as copy blocks (headings, list items, code, tables, quotes).
  @MainActor
  func blocks(ranges: [NSRange?], wholeMessage: Bool) -> [MessageClipboardDocument.Block] {
    guard let parts = RichTextMultiSurfaceSelection.documentParts(
      document: document,
      surfaceRanges: ranges,
      includeDocumentEdges: wholeMessage
    ) else { return [] }
    return MessageClipboardDocument.blocks(
      parts: parts,
      surfaceTexts: textViews.map(\.surfaceText),
      roles: roles,
      literals: literals,
      literalRoles: literalRoles
    )
  }

  /// The whole message as copy blocks.
  @MainActor
  func wholeMessageBlocks() -> [MessageClipboardDocument.Block] {
    let lengths = lengths
    guard let last = lengths.indices.last,
          let ranges = RichTextMultiSurfaceSelection.ranges(
            surfaceLengths: lengths,
            anchor: .init(surfaceIndex: 0, utf16Offset: 0),
            head: .init(surfaceIndex: last, utf16Offset: lengths[last])
          )
    else { return [] }
    return blocks(ranges: ranges, wholeMessage: true)
  }

  /// The whole message for a menu's Copy when it has structure: headings, list items, code,
  /// tables or quotes. Nil for paragraphs alone, which copy best from the message's own text
  /// and formatting.
  @MainActor
  func structuredWholeMessageDocument() -> MessageClipboardDocument? {
    let blocks = wholeMessageBlocks()
    guard blocks.contains(where: { if case .paragraph = $0 { false } else { true } }) else { return nil }
    return MessageClipboardDocument(blocks: blocks)
  }
}

/// A rendered message whose text can join a selection that spans blocks and messages.
@MainActor
protocol MessageTextSelectionSource: NSView {
  func textSelectionProjection() -> MessageTextSelectionProjection?
  /// Where a press may start a text selection, in this view's coordinates: the text with a
  /// margin and the bubble around it. Nil when the message shows no text.
  func textSelectionPressRegion() -> CGRect?
  /// Whether a point (in this view's coordinates) is on something with its own clicks or drags:
  /// media, reactions, buttons, replies, names.
  func isInteractiveForTextSelection(at point: NSPoint) -> Bool
}

/// What the message list provides to its text selection.
@MainActor
protocol MessageListTextSelectionHost: AnyObject {
  /// Where the list's rows are: the table list's table, or the timeline list.
  var textSelectionRows: any MessageListRowGeometry { get }
  var textSelectionRootView: NSView { get }
  var isMessageSelectionActive: Bool { get }
  func textSelectionStableId(atRow row: Int) -> Int64?
  func textSelectionRow(forStableId stableId: Int64) -> Int?
  func textSelectionMessage(atRow row: Int) -> FullMessage?
  func messageSelectionStableId(atRow row: Int) -> Int64?
  @discardableResult func beginMessageSelection(atRow row: Int) -> Bool
  func setSelectedMessageStableIds(_ stableIds: Set<Int64>)
}

/// Drag selection in the message list, like Telegram:
/// - Pressing on text and dragging into another text block or message selects text across
///   them. Within one text view, NSTextView keeps its native selection.
/// - Pressing beside text (bubble padding, beside or between bubbles) and dragging into another
///   message enters message selection and selects every message the drag passes.
/// A click, or a drag that stays in its own message, behaves exactly as before.
@MainActor
final class MessageListTextSelection {
  struct Endpoint: Equatable {
    var stableId: Int64
    var surface: Int
    var offset: Int
  }

  private enum Gesture {
    case text(anchor: Endpoint, origin: NSPoint, active: Bool)
    case messages(anchorStableId: Int64, origin: NSPoint, active: Bool)
  }

  private(set) weak var host: MessageListTextSelectionHost?
  private var eventMonitor: Any?
  private var gesture: Gesture?
  /// The view under the press that started the gesture. Its hold gestures (reactions and
  /// other hold actions) never see the drags the list consumes, so the list cancels them.
  private weak var pressedView: NSView?
  private var autoscrollTimer: Timer?
  /// Endpoints in drag order. Nil when nothing is selected.
  private(set) var selection: (anchor: Endpoint, head: Endpoint)?
  /// Text views currently drawing part of the selection, including recycled offscreen cells.
  private let highlighted = NSHashTable<NSView>.weakObjects()
  /// Selected text per message from when it was last on screen, so copy stays faithful for
  /// messages scrolled away (and recycled) during a long drag.
  private var fragments: [Int64: (ranges: [NSRange?], blocks: [MessageClipboardDocument.Block])] = [:]
  private var refreshScheduled = false

  private static let dragThresholdSquared: CGFloat = 9

  init(host: MessageListTextSelectionHost) {
    self.host = host
  }

  #if DEBUG
  /// The timeline journey harness drives the list with posted events while the Mac may be locked, when no app can be
  /// active and no window key: it treats its window as key for presses. Debug builds only.
  static var treatsWindowAsKey = false
  #else
  static var treatsWindowAsKey: Bool { false }
  #endif

  var hasSelection: Bool { selection != nil }

  /// A press that may become a selection drag. The table must not start its own mouse
  /// tracking for it, or the drag never reaches the list.
  var ownsPendingPress: Bool { gesture != nil }

  /// Another gesture took the press (a hold action, Look Up), so it never becomes a selection.
  func cancelPendingPress() {
    guard gesture != nil else { return }
    endGesture()
  }

  // MARK: Lifecycle

  /// The selections of the lists in the app's windows, so a message view finds its list's selection whatever the list
  /// is (the table list's table, or the timeline list).
  private static let installed = NSHashTable<MessageListTextSelectionBox>.weakObjects()
  private lazy var box = MessageListTextSelectionBox(self)

  func install() {
    Self.installed.add(box)
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
    ) { [weak self] event in
      guard let self else { return event }
      return self.handle(event)
    }
  }

  func uninstall() {
    Self.installed.remove(box)
    endGesture()
    clear()
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
  }

  /// Finds the list that owns a message view's selection.
  static func owner(of view: NSView) -> MessageListTextSelection? {
    var ancestor: NSView? = view
    while let current = ancestor {
      if let table = current as? MessageListTableView { return table.textSelection }
      ancestor = current.superview
    }
    for box in installed.allObjects {
      guard let selection = box.selection, let rows = selection.host?.textSelectionRows else { continue }
      if view === rows.rowsView || view.isDescendant(of: rows.rowsView) { return selection }
    }
    return nil
  }

  /// Adds "Copy Selected Text" to a message menu when the list's selection covers that message.
  static func retargetCopy(in menu: NSMenu, from view: NSView) -> NSMenu {
    guard let owner = owner(of: view), owner.covers(view) else { return menu }
    let copyAction = #selector(NSText.copy(_:))
    for item in menu.items where item.keyEquivalent == "c" && item.keyEquivalentModifierMask == .command {
      item.keyEquivalent = ""
    }
    let item = NSMenuItem(title: "Copy Selected Text", action: copyAction, keyEquivalent: "c")
    item.target = owner.host?.textSelectionRows.keyView
    menu.insertItem(item, at: 0)
    if menu.items.count > 1 { menu.insertItem(.separator(), at: 1) }
    return menu
  }

  // MARK: Events

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard let host, let window = host.textSelectionRootView.window, event.window === window else { return event }
    switch event.type {
    case .leftMouseDown:
      endGesture()
      if extendSelection(with: event, host: host, window: window) { return event }
      // Any other press ends the previous selection, inside the list or not.
      clear()
      beginGesture(with: event, host: host, window: window)
      return event
    case .leftMouseDragged:
      return drag(to: event.locationInWindow) ? nil : event
    case .leftMouseUp:
      finishGesture(at: event.locationInWindow)
      return event
    case .keyDown:
      guard hasSelection, event.keyCode == 53,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            let responder = window.firstResponder as? NSView,
            host.textSelectionRows.ownsResponder(responder)
      else { return event }
      clear()
      return nil
    default:
      return event
    }
  }

  /// The pressed message text, if the press may select: text that is not a link or mention.
  private func textPress(
    _ event: NSEvent,
    host: MessageListTextSelectionHost,
    window: NSWindow
  ) -> (row: Int, stableId: Int64, cell: MessageTableCell?, hit: NSView)? {
    guard window.isKeyWindow || Self.treatsWindowAsKey, window.attachedSheet == nil, !host.isMessageSelectionActive
    else { return nil }
    let rows = host.textSelectionRows
    guard let hit = rows.hit(atWindowPoint: event.locationInWindow),
          let row = rows.row(at: rows.rowsView.convert(event.locationInWindow, from: nil)),
          let stableId = host.textSelectionStableId(atRow: row)
    else { return nil }
    return (row, stableId, rows.cell(atRow: row), hit)
  }

  /// Shift-click on text moves the end of the current selection there.
  private func extendSelection(with event: NSEvent, host: MessageListTextSelectionHost, window: NSWindow) -> Bool {
    let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
    guard modifiers == .shift, event.clickCount == 1, let selection,
          let press = textPress(event, host: host, window: window),
          press.hit is any MessageTextSurface,
          let head = headEndpoint(at: event.locationInWindow, anchor: selection.anchor)
    else { return false }
    self.selection = (selection.anchor, head)
    refreshVisible()
    gesture = .text(anchor: selection.anchor, origin: event.locationInWindow, active: true)
    pressedView = press.hit
    return true
  }

  private func beginGesture(with event: NSEvent, host: MessageListTextSelectionHost, window: NSWindow) {
    guard event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
          let press = textPress(event, host: host, window: window)
    else { return }
    let rows = host.textSelectionRows
    let table = rows.rowsView
    pressedView = press.hit

    if let textView = press.hit as? any MessageTextSurface {
      // Links and mentions act on press; they never start a selection.
      if case .text = textView.entityHit(
        at: textView.convert(event.locationInWindow, from: nil),
        extraTextRanges: []
      ) {
        return
      }
      guard let cell = press.cell, textView.isDescendant(of: cell),
            let projection = cell.textSelectionSource?.textSelectionProjection(),
            let anchor = endpoint(in: projection, stableId: press.stableId, at: event.locationInWindow, table: table)
      else { return }
      switch event.clickCount {
      case 1:
        gesture = .text(anchor: anchor, origin: event.locationInWindow, active: false)
      case 2:
        selectUnit(.word, around: anchor, in: projection)
      default:
        selectUnit(.paragraph, around: anchor, in: projection)
      }
    } else if event.clickCount == 1, let anchor = paddedTextAnchor(for: event, press: press, table: table) {
      // Empty space in and around the bubble selects text from the nearest character, so
      // selections can start before the first word or after the last.
      gesture = .text(anchor: anchor, origin: event.locationInWindow, active: false)
    } else if event.clickCount == 1, press.hit as? NSTextView == nil,
              startsMessageDrag(press.hit, in: press.cell ?? table, rows: rows),
              host.messageSelectionStableId(atRow: press.row) != nil
    {
      // Beside text: the drag selects whole messages once it reaches another message.
      gesture = .messages(anchorStableId: press.stableId, origin: event.locationInWindow, active: false)
    }
  }

  private enum Unit { case word, paragraph }

  /// Double click selects a word, triple click a paragraph, like native text.
  private func selectUnit(_ unit: Unit, around point: Endpoint, in projection: MessageTextSelectionProjection) {
    guard projection.textViews.indices.contains(point.surface),
          case let storage = projection.textViews[point.surface].surfaceText, storage.length > 0
    else { return }
    let index = min(point.offset, storage.length - 1)
    let range: NSRange
    switch unit {
    case .word:
      range = storage.doubleClick(at: index)
    case .paragraph:
      range = (storage.string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
    }
    guard range.length > 0 else { return }
    selection = (
      Endpoint(stableId: point.stableId, surface: point.surface, offset: range.location),
      Endpoint(stableId: point.stableId, surface: point.surface, offset: NSMaxRange(range))
    )
    refreshVisible()
    gesture = .text(anchor: selection!.anchor, origin: .zero, active: true)
  }

  /// The nearest text position for a press in a message's padded text region, unless the
  /// press is on something with its own clicks or drags.
  private func paddedTextAnchor(
    for event: NSEvent,
    press: (row: Int, stableId: Int64, cell: MessageTableCell?, hit: NSView),
    table: NSView
  ) -> Endpoint? {
    guard let source = press.cell?.textSelectionSource,
          let region = source.textSelectionPressRegion()
    else { return nil }
    let point = source.convert(event.locationInWindow, from: nil)
    guard region.contains(point), !source.isInteractiveForTextSelection(at: point) else { return nil }
    var current: NSView? = press.hit
    while let view = current, view !== press.cell {
      let isControl = view is NSControl && !(view is NSImageView) && !(view is NSTextField)
      // Text views are dragging sources too, but presses on message text belong to selection.
      let dragsContent = view is NSDraggingSource && !(view is NSTextView)
      if isControl || view is NSScroller || view is WKWebView || dragsContent { return nil }
      current = view.superview
    }
    guard let projection = source.textSelectionProjection() else { return nil }
    return endpoint(in: projection, stableId: press.stableId, at: event.locationInWindow, table: table)
  }

  /// Presses on controls, media, reactions or widgets keep their own drags and clicks.
  private func startsMessageDrag(_ hit: NSView, in container: NSView, rows: any MessageListRowGeometry) -> Bool {
    var current: NSView? = hit
    while let view = current, view !== container.superview {
      if view is NSControl || view is NSScroller || view is WKWebView || view is NSDraggingSource
        || view is NSTextView
      {
        return false
      }
      current = view.superview
    }
    // Only plain backgrounds: the list, rows, the message and its bubble.
    return rows.isRowBackground(hit) || hit is MessageTableCell
      || hit is MessageTextSelectionSource || hit is MessageBubbleBackgroundView
      || hit is MessageBubbleTailView || type(of: hit) == NSView.self
  }

  private func drag(to windowPoint: NSPoint) -> Bool {
    guard let gesture, let host else { return false }
    switch gesture {
    case let .text(anchor, origin, active):
      if !active {
        guard moved(from: origin, to: windowPoint) else { return true }
        self.gesture = .text(anchor: anchor, origin: origin, active: true)
      }
      cancelPressHolds()
      if let head = headEndpoint(at: windowPoint, anchor: anchor) {
        selection = (anchor, head)
        refreshVisible()
      }
      updateAutoscroll(windowPoint: windowPoint)
      return true

    case let .messages(anchorStableId, origin, active):
      let rows = host.textSelectionRows
      guard let anchorRow = host.textSelectionRow(forStableId: anchorStableId) else {
        endGesture()
        return false
      }
      let row = rows.clampedRow(at: rows.rowsView.convert(windowPoint, from: nil))
      if !active {
        guard moved(from: origin, to: windowPoint), let row, row != anchorRow,
              host.textSelectionStableId(atRow: row) != nil
        else { return false }
        guard host.beginMessageSelection(atRow: anchorRow), host.isMessageSelectionActive else {
          endGesture()
          return false
        }
        self.gesture = .messages(anchorStableId: anchorStableId, origin: origin, active: true)
      }
      guard host.isMessageSelectionActive else {
        endGesture()
        return true
      }
      cancelPressHolds()
      if let row {
        let ids = (min(anchorRow, row) ... max(anchorRow, row)).compactMap { host.messageSelectionStableId(atRow: $0) }
        host.setSelectedMessageStableIds(Set(ids))
      }
      updateAutoscroll(windowPoint: windowPoint)
      return true
    }
  }

  private func finishGesture(at windowPoint: NSPoint) {
    guard let gesture else { return }
    endGesture()
    guard case .text(_, _, true) = gesture else { return }
    guard !clipboardDocument().isEmpty, let host else { return clear() }
    // Copy, Escape and the Edit menu reach the list from here.
    let keyView = host.textSelectionRows.keyView
    keyView.window?.makeFirstResponder(keyView)
    if let textView = singleMessageHeadView() {
      MessageSelectionMenu.selectionTrackingEnded(in: textView, at: windowPoint)
    }
  }

  /// The press became a drag. From here the list consumes the drags, so the pressed message's
  /// hold timer and press recognizers would see a still pointer and fire; cancel them.
  private func cancelPressHolds() {
    guard let host, let pressed = pressedView else { return }
    pressedView = nil
    let table = host.textSelectionRows.rowsView
    var current: NSView? = pressed
    while let view = current, view !== table {
      current = view.superview
      // Text views hold through a timer; their own recognizers are NSTextView internals.
      if let textView = view as? any MessageTextSurface {
        textView.cancelPendingTextHold()
        continue
      }
      if view is NSTextView { continue }
      for recognizer in view.gestureRecognizers
        where recognizer.isEnabled && (recognizer is NSPressGestureRecognizer || recognizer is NSClickGestureRecognizer)
      {
        // Disabling resets a recognizer, which cancels a pending recognition.
        recognizer.isEnabled = false
        recognizer.isEnabled = true
      }
    }
  }

  private func endGesture() {
    gesture = nil
    pressedView = nil
    autoscrollTimer?.invalidate()
    autoscrollTimer = nil
  }

  private func moved(from origin: NSPoint, to point: NSPoint) -> Bool {
    let dx = point.x - origin.x
    let dy = point.y - origin.y
    return dx * dx + dy * dy >= Self.dragThresholdSquared
  }

  // MARK: Endpoints

  /// The selection end for the pointer. Over a row without text (a date, a photo), the selection
  /// ends at the edge of the nearest text toward the anchor, like native text selection.
  private func headEndpoint(at windowPoint: NSPoint, anchor: Endpoint) -> Endpoint? {
    let rows = host?.textSelectionRows
    guard let host, let rows, let pointerRow = rows.clampedRow(at: rows.rowsView.convert(windowPoint, from: nil)),
          let anchorRow = host.textSelectionRow(forStableId: anchor.stableId)
    else { return nil }
    let table = rows.rowsView
    var row = pointerRow
    while true {
      if let stableId = host.textSelectionStableId(atRow: row),
         let projection = projection(atRow: row)
      {
        if row == pointerRow {
          return endpoint(in: projection, stableId: stableId, at: windowPoint, table: table)
        }
        if row < pointerRow {
          let last = projection.textViews.count - 1
          return Endpoint(stableId: stableId, surface: last, offset: projection.lengths[last])
        }
        return Endpoint(stableId: stableId, surface: 0, offset: 0)
      }
      if row == anchorRow { return nil }
      row += row < anchorRow ? 1 : -1
    }
  }

  private func projection(atRow row: Int) -> MessageTextSelectionProjection? {
    guard let cell = host?.textSelectionRows.cell(atRow: row),
      let projection = cell.textSelectionSource?.textSelectionProjection(),
      !projection.textViews.isEmpty
    else { return nil }
    return projection
  }

  /// The insertion point in the text view under (or nearest to) the pointer.
  private func endpoint(
    in projection: MessageTextSelectionProjection,
    stableId: Int64,
    at windowPoint: NSPoint,
    table: NSView
  ) -> Endpoint? {
    let point = table.convert(windowPoint, from: nil)
    var nearest: (surface: Int, rect: CGRect, distance: CGFloat)?
    for (surface, textView) in projection.textViews.enumerated() {
      guard textView.window != nil, !textView.isHiddenOrHasHiddenAncestor else { continue }
      let rect = textView.convert(textView.bounds.intersection(textView.visibleRect), to: table)
      guard rect.width > 0, rect.height > 0 else { continue }
      let dx = point.x < rect.minX ? rect.minX - point.x : (point.x > rect.maxX ? point.x - rect.maxX : 0)
      let dy = point.y < rect.minY ? rect.minY - point.y : (point.y > rect.maxY ? point.y - rect.maxY : 0)
      let distance = dx * dx + dy * dy
      if nearest == nil || distance < nearest!.distance {
        nearest = (surface, rect, distance)
      }
      if distance == 0 { break }
    }
    guard let nearest else { return nil }
    let textView = projection.textViews[nearest.surface]
    let length = projection.lengths[nearest.surface]
    let clamped = NSPoint(
      x: min(max(point.x, nearest.rect.minX + 1), nearest.rect.maxX - 1),
      y: min(max(point.y, nearest.rect.minY + 1), nearest.rect.maxY - 1)
    )
    let isAbove = table.isFlipped ? point.y < nearest.rect.minY : point.y > nearest.rect.maxY
    let isBelow = table.isFlipped ? point.y > nearest.rect.maxY : point.y < nearest.rect.minY
    let offset: Int
    if isAbove {
      offset = 0
    } else if isBelow {
      offset = length
    } else {
      offset = textView.selectionInsertionIndex(at: textView.convert(clamped, from: table)) ?? 0
    }
    return Endpoint(stableId: stableId, surface: nearest.surface, offset: min(max(0, offset), length))
  }

  /// Lower and upper endpoints with their rows, in list order.
  private func orderedBounds() -> (lower: Endpoint, lowerRow: Int, upper: Endpoint, upperRow: Int)? {
    guard let selection, let host,
          let anchorRow = host.textSelectionRow(forStableId: selection.anchor.stableId),
          let headRow = host.textSelectionRow(forStableId: selection.head.stableId)
    else { return nil }
    let a = (anchorRow, selection.anchor.surface, selection.anchor.offset)
    let h = (headRow, selection.head.surface, selection.head.offset)
    return a <= h
      ? (selection.anchor, anchorRow, selection.head, headRow)
      : (selection.head, headRow, selection.anchor, anchorRow)
  }

  /// Per-text-view ranges for one message row, or nil when the row is outside the selection.
  private func ranges(
    forRow row: Int,
    lengths: [Int]
  ) -> (ranges: [NSRange?], wholeMessage: Bool)? {
    guard let bounds = orderedBounds(), !lengths.isEmpty,
          row >= bounds.lowerRow, row <= bounds.upperRow
    else { return nil }
    let last = lengths.count - 1
    let start = row == bounds.lowerRow
      ? RichTextMultiSurfaceSelection.Endpoint(
        surfaceIndex: min(bounds.lower.surface, last),
        utf16Offset: bounds.lower.offset
      )
      : .init(surfaceIndex: 0, utf16Offset: 0)
    let end = row == bounds.upperRow
      ? RichTextMultiSurfaceSelection.Endpoint(
        surfaceIndex: min(bounds.upper.surface, last),
        utf16Offset: bounds.upper.offset
      )
      : .init(surfaceIndex: last, utf16Offset: lengths[last])
    guard let ranges = RichTextMultiSurfaceSelection.ranges(surfaceLengths: lengths, anchor: start, head: end)
    else { return nil }
    let whole = start.surfaceIndex == 0 && start.utf16Offset == 0
      && end.surfaceIndex == last && end.utf16Offset >= lengths[last]
    return (ranges, whole)
  }

  // MARK: Highlight

  /// Applies the selection to a cell the table just configured (scrolling, reuse, reloads).
  func cellDidConfigure(_ cell: MessageTableCell, row: Int) {
    guard hasSelection, let stableId = host?.textSelectionStableId(atRow: row) else { return }
    apply(to: cell, row: row, stableId: stableId)
  }

  /// Coalesces refreshes for layout changes that rebuild text views without reconfiguring cells.
  func setNeedsRefresh() {
    guard hasSelection, !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.refreshScheduled = false
      self.refreshVisible()
    }
  }

  private func refreshVisible() {
    guard let host, hasSelection else { return clear() }
    guard orderedBounds() != nil else { return clear() }
    let rows = host.textSelectionRows
    var touched = Set<ObjectIdentifier>()
    for row in rows.placedRows {
      guard let cell = rows.cell(atRow: row), let stableId = host.textSelectionStableId(atRow: row) else { continue }
      for textView in apply(to: cell, row: row, stableId: stableId) {
        touched.insert(ObjectIdentifier(textView))
      }
    }
    for view in highlighted.allObjects where !touched.contains(ObjectIdentifier(view)) {
      (view as? any MessageTextSurface)?.listSelectionRange = nil
      highlighted.remove(view)
    }
  }

  @discardableResult
  private func apply(to cell: MessageTableCell, row: Int, stableId: Int64) -> [any MessageTextSurface] {
    guard let projection = cell.textSelectionSource?.textSelectionProjection() else { return [] }
    let lengths = projection.lengths
    let planned = ranges(forRow: row, lengths: lengths)
    for (index, textView) in projection.textViews.enumerated() {
      let range = planned?.ranges[index]
      textView.listSelectionRange = (range?.length ?? 0) > 0 ? range : nil
      if textView.listSelectionRange != nil {
        highlighted.add(textView)
      } else {
        highlighted.remove(textView)
      }
    }
    if let planned {
      if fragments[stableId]?.ranges != planned.ranges {
        fragments[stableId] = (
          planned.ranges,
          projection.blocks(ranges: planned.ranges, wholeMessage: planned.wholeMessage)
        )
      }
    } else {
      fragments[stableId] = nil
    }
    return projection.textViews
  }

  func clear() {
    selection = nil
    fragments = [:]
    for view in highlighted.allObjects {
      (view as? any MessageTextSurface)?.listSelectionRange = nil
    }
    highlighted.removeAllObjects()
  }

  /// The text view holding the selection's end when the selection lies in one message.
  private func singleMessageHeadView() -> (any MessageTextSurface)? {
    guard let selection, let bounds = orderedBounds(), bounds.lowerRow == bounds.upperRow,
          let projection = projection(atRow: bounds.upperRow),
          projection.textViews.indices.contains(selection.head.surface)
    else { return nil }
    return projection.textViews[selection.head.surface]
  }

  /// The selected text when the selection lies entirely in the message containing `view`.
  func selectedText(onlyIn view: NSView) -> String? {
    guard let host, let bounds = orderedBounds(), bounds.lowerRow == bounds.upperRow,
          host.textSelectionRows.row(containing: view) == bounds.lowerRow
    else { return nil }
    let document = clipboardDocument()
    return document.isEmpty ? nil : document.plainText
  }

  /// Whether the selection includes any text of the message containing `view`.
  func covers(_ view: NSView) -> Bool {
    guard hasSelection, let host, let row = host.textSelectionRows.row(containing: view),
          let bounds = orderedBounds()
    else { return false }
    return row >= bounds.lowerRow && row <= bounds.upperRow
  }

  // MARK: Autoscroll

  private func updateAutoscroll(windowPoint: NSPoint) {
    guard let visible = autoscrollRegion() else { return }
    let outside = windowPoint.y < visible.minY + 8 || windowPoint.y > visible.maxY - 8
    guard outside else {
      autoscrollTimer?.invalidate()
      autoscrollTimer = nil
      return
    }
    guard autoscrollTimer == nil else { return }
    // Common modes: NSTextView's and NSTableView's mouse tracking run the event-tracking mode.
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.autoscrollTick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    autoscrollTimer = timer
  }

  /// The list's visible message area in window coordinates, past toolbar and composer insets.
  private func autoscrollRegion() -> NSRect? {
    host?.textSelectionRows.autoscrollRegion(insetsOnly: true)
  }

  private func autoscrollTick() {
    guard gesture != nil, let host, let window = host.textSelectionRootView.window,
          let visible = autoscrollRegion()
    else { return endGesture() }
    let point = window.mouseLocationOutsideOfEventStream
    let edge: CGFloat = 8
    let distance = point.y < visible.minY + edge ? point.y - (visible.minY + edge)
      : point.y > visible.maxY - edge ? point.y - (visible.maxY - edge) : 0
    guard distance != 0 else {
      autoscrollTimer?.invalidate()
      autoscrollTimer = nil
      return
    }
    // Faster the further past the edge, like the message selection drag.
    let step = min(max(abs(distance) * 0.6, 6), 40) * (distance > 0 ? 1 : -1)
    guard host.textSelectionRows.autoscroll(by: step) else { return }
    _ = drag(to: point)
  }

  // MARK: Copy

  /// The selection as copy blocks in list order, messages separated like paragraphs. Text
  /// selections never add sender names; copying checked messages does.
  func clipboardDocument() -> MessageClipboardDocument {
    guard let host, let bounds = orderedBounds() else { return MessageClipboardDocument(blocks: []) }
    var blocks: [MessageClipboardDocument.Block] = []
    for row in bounds.lowerRow ... bounds.upperRow {
      guard let stableId = host.textSelectionStableId(atRow: row) else { continue }
      if let projection = projection(atRow: row),
         let planned = ranges(forRow: row, lengths: projection.lengths)
      {
        blocks += projection.blocks(ranges: planned.ranges, wholeMessage: planned.wholeMessage)
      } else if let cached = fragments[stableId] {
        blocks += cached.blocks
      } else if row != bounds.lowerRow, row != bounds.upperRow,
                let message = host.textSelectionMessage(atRow: row)
      {
        // Never on screen during the drag: the whole message.
        blocks += Self.messageBlocks(message)
      }
    }
    return MessageClipboardDocument(blocks: blocks.filter {
      if case let .paragraph(text) = $0 { return !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      return true
    })
  }

  /// A whole message as copy blocks: from its rendered text views when on screen, so rich
  /// structure survives, otherwise from its text and formatting.
  func wholeMessageBlocks(_ message: FullMessage) -> [MessageClipboardDocument.Block] {
    if let host, let row = host.textSelectionRow(forStableId: message.id),
       let blocks = projection(atRow: row)?.wholeMessageBlocks(), !blocks.isEmpty
    {
      return blocks
    }
    return Self.messageBlocks(message)
  }

  private static func messageBlocks(_ message: FullMessage) -> [MessageClipboardDocument.Block] {
    guard let text = message.message.text, !text.isEmpty else { return [] }
    return [.paragraph(.init(string: text, entities: message.message.entities?.entities ?? []))]
  }

  @discardableResult
  func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
    MessageClipboard.write(clipboardDocument(), to: pasteboard)
  }
}

/// A weak handle on a list's selection, for the registry of installed selections.
@MainActor
final class MessageListTextSelectionBox: NSObject {
  weak var selection: MessageListTextSelection?
  init(_ selection: MessageListTextSelection) {
    self.selection = selection
  }
}

/// The message list's table. It takes first responder after a text selection across messages
/// so Edit > Copy and Cmd-C copy that selection.
final class MessageListTableView: NSTableView {
  weak var textSelection: MessageListTextSelection?

  override func mouseDown(with event: NSEvent) {
    // Rows are never selected through the table; a press beside text belongs to the list's drag.
    if textSelection?.ownsPendingPress == true { return }
    super.mouseDown(with: event)
  }

  @objc func copy(_: Any?) {
    if textSelection?.copySelection() != true { NSSound.beep() }
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(NSText.copy(_:)) { return textSelection?.hasSelection == true }
    return super.validateUserInterfaceItem(item)
  }
}


