import AppKit
import QuartzCore
import TimelineCore

// Telegram macOS's configuration (`TGUIKit/TableView` over an unflipped NSTableView, see
// secret-sauce 2026-11-27-telegram-macos-list-deep-dive.md §1.1–1.5, 3.2, 3.5), rebuilt on a custom unflipped document
// of frame-laid-out rows rather than NSTableView, as the baseline for the NSScrollView prototype:
//
// - The document is NOT flipped: y = 0 is its bottom, the clip origin y = 0 shows the bottom, "at bottom" is
//   origin ≤ 0.5. History landing above grows the document upward and moves nothing on screen.
// - The document holds a sliding window of loaded rows (90 by default) with exact heights: its height is their sum,
//   not the chat's. Near a window edge (count / 6 rows), at most every 50 ms, a new window anchored on the edge row on
//   screen replaces it in one grouped update that puts the anchor row back where it was on screen (`saveVisible`).
// - The composer is a spacer row at the bottom of the document, not a bottom content inset.
// - Responsive scrolling untouched; per bounds change only rows entering the visible or prepared rect are realised
//   (as NSTableView tiles); the window bookkeeping is coalesced to once per run-loop turn.
//
// The core is used only for what Telegram does by hand: nothing here needs TimelineState (no reading-row solver), so
// the comparison is Telegram's mechanism against ours.

@MainActor
public final class WindowedScrollList<ID: Hashable & Sendable>: NSView {
  public final class Document: NSView {
    // Unflipped: row 0 of the window (the composer spacer) at the bottom.
    override public class var isCompatibleWithResponsiveScrolling: Bool { true }
    var onPrepare: ((NSRect) -> Void)?
    override public func prepareContent(in rect: NSRect) {
      onPrepare?(rect)
      super.prepareContent(in: rect)
    }
  }

  public let scrollView = NSScrollView()
  public let document = Document()
  public var clip: NSClipView { scrollView.contentView }
  public var rows: ScrollListRows<ID>
  public var onDemand: ((Set<TimelineEdge>) -> Void)?
  public private(set) var stats = ScrollListStats()

  /// Rows the window holds (Telegram: 90 messages) and how close to its edge a new one is asked for (count / 6).
  public var windowSize = 90
  /// All loaded rows, oldest first.
  public private(set) var all: [ID] = []
  var indexOf: [ID: Int] = [:]
  public private(set) var coverage = TimelineCoverage()
  /// The window: indexes into `all`, [lo, hi).
  public private(set) var lo = 0
  public private(set) var hi = 0
  /// Per window row, newest first: its height and its bottom in the document (above the spacer).
  var heights: [CGFloat] = []
  var bottoms: [CGFloat] = []
  var spacer: CGFloat = 0
  var topInset: CGFloat = 0
  var width: CGFloat = 0
  var views: [ID: NSView] = [:]
  var prepared: NSRect = .zero
  var lastMerge: CFTimeInterval = 0
  var bookkeepingQueued = false
  var isAdjusting = false
  public private(set) var isLiveScrolling = false
  /// Clip moves the list made that keep what shows (saveVisible), accumulated: the scroll position with them taken
  /// out is continuous (diagnostics).
  public private(set) var preservingShift: CGFloat = 0
  var trackSerial = 0
  var lastScrollY: CGFloat = 0
  var direction: TimelineEdge?
  var pendingDemand = false

  nonisolated override public var isFlipped: Bool { true }

  public init(rows: ScrollListRows<ID>) {
    self.rows = rows
    super.init(frame: .zero)
    wantsLayer = true
    scrollView.wantsLayer = true
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.verticalScrollElasticity = .allowed
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.autohidesScrollers = true
    clip.drawsBackground = false
    clip.postsBoundsChangedNotifications = true
    document.wantsLayer = true
    document.onPrepare = { [weak self] rect in self?.prepare(rect) }
    scrollView.documentView = document
    addSubview(scrollView)
    NotificationCenter.default.addObserver(
      self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(liveStarted(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(liveEnded(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView
    )
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError() }

  isolated deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Geometry

  public var scrollY: CGFloat { clip.bounds.origin.y }
  public var isAtBottom: Bool { scrollY <= 0.5 }
  var clipHeight: CGFloat { clip.bounds.height }
  var documentHeight: CGFloat { (bottoms.last.map { $0 + (heights.last ?? 0) } ?? 0) + spacer }

  /// Window position (0 = newest of the window) of a row.
  func slot(of id: ID) -> Int? {
    guard let index = indexOf[id], index >= lo, index < hi else { return nil }
    return hi - 1 - index
  }

  func id(atSlot slot: Int) -> ID { all[hi - 1 - slot] }

  /// The document rect of a window row (unflipped).
  func rect(ofSlot slot: Int) -> NSRect {
    NSRect(x: 0, y: spacer + bottoms[slot], width: width, height: heights[slot])
  }

  /// Where a row shows now, in this view's (flipped) coordinates.
  public func presentedFrame(for id: ID) -> CGRect? {
    guard let slot = slot(of: id), let view = views[id] else { return nil }
    let r = rect(ofSlot: slot)
    let top = presentedScrollY + clipHeight - r.maxY
    return CGRect(x: 0, y: top, width: view.frame.width, height: r.height)
  }

  /// The clip's origin as shown, with an additive track on the document (an animated change) taken in.
  public var presentedScrollY: CGFloat {
    guard let layer = clip.layer else { return scrollY }
    let clipY = (layer.presentation() ?? layer).bounds.origin.y
    guard let docLayer = document.layer else { return clipY }
    let shown = (docLayer.presentation() ?? docLayer).position.y
    return clipY - (shown - docLayer.position.y)
  }

  public var placedViews: [(ID, NSView)] { views.map { ($0.key, $0.value) } }
  public var isMoving: Bool { isLiveScrolling }

  // MARK: - Changes

  /// Data, insets, scroll in one pass.
  public func apply(
    rows newRows: [ID]?, coverage newCoverage: TimelineCoverage?, scroll: TimelineScroll<ID>, top: CGFloat?,
    bottom: CGFloat?, changed: Set<ID>, timing: TimelineTiming
  ) {
    let began = CACurrentMediaTime()
    defer {
      stats.performs += 1
      stats.performSeconds += CACurrentMediaTime() - began
    }
    if let top, top != topInset {
      topInset = top
      let origin = clip.bounds.origin
      isAdjusting = true
      scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
      if clip.bounds.origin != origin { clip.setBoundsOrigin(origin) }
      isAdjusting = false
    }
    if let newCoverage { coverage = newCoverage }
    let snapshot = visibleSnapshot()
    let wasAtBottom = isAtBottom && !isLiveScrolling
    var spacerDelta: CGFloat = 0
    if let bottom, bottom != spacer {
      spacerDelta = bottom - spacer
      spacer = bottom
    }
    var appendedHeight: CGFloat = 0
    if let newRows {
      let oldHi = hi
      let oldAll = all
      all = newRows
      indexOf = Dictionary(uniqueKeysWithValues: newRows.enumerated().map { ($0.element, $0.offset) })
      if oldAll.isEmpty {
        hi = all.count
        lo = max(0, hi - windowSize)
      } else {
        // Keep the same rows in the window; rows appended after the window's newest row join it when the window
        // reached the newest (Telegram's window follows the bottom while at the live end).
        let keepLo = oldAll.indices.contains(lo) ? indexOf[oldAll[lo]] : nil
        let keepHi = oldHi > 0 && oldAll.indices.contains(oldHi - 1) ? indexOf[oldAll[oldHi - 1]].map { $0 + 1 } : nil
        lo = keepLo ?? 0
        hi = keepHi ?? all.count
        if oldHi == oldAll.count { hi = all.count }
        lo = min(lo, hi)
        for index in (keepHi ?? hi) ..< hi { appendedHeight += rows.height(all[index], width) }
      }
    }
    relayoutWindow(changed: changed)
    // Where the reader goes.
    switch scroll {
      case .latest:
        if lo > 0, hi < all.count || hi - lo < windowSize { slide(lo: max(0, all.count - windowSize), hi: all.count) }
        if timing.isAnimated { animateScroll(to: 0) } else { setClip(0, preserving: false) }
      case let .to(id, alignment):
        scrollTo(id, alignment: alignment, animated: timing.isAnimated)
      case let .by(delta):
        setClip(scrollY + delta, preserving: false)
      case .preserve:
        if wasAtBottom {
          // Pinned: the bottom stays shown; what was above moves up by the arrivals and the spacer's change.
          setClip(0, preserving: false)
          let moved = appendedHeight + spacerDelta
          if timing.isAnimated, window != nil { addDocumentTrack(timing, from: -moved) }
        } else {
          saveVisible(snapshot, timing: spacerDelta != 0 ? timing : .none)
        }
    }
    realise()
  }

  // MARK: - Window

  /// Measures the window's rows and lays the document out (one grouped update: frame, then every realised row).
  func relayoutWindow(changed: Set<ID> = []) {
    width = clip.bounds.width
    heights = []
    bottoms = []
    var y: CGFloat = 0
    var slot = 0
    var index = hi - 1
    while index >= lo {
      let h = max(0, rows.height(all[index], width))
      heights.append(h)
      bottoms.append(y)
      y += h
      slot += 1
      index -= 1
    }
    let height = max(documentHeight, 1)
    isAdjusting = true
    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    if document.frame != frame { document.frame = frame }
    isAdjusting = false
    for (id, view) in views {
      guard let slot = self.slot(of: id) else { continue }
      let r = rect(ofSlot: slot)
      if view.frame != r { view.frame = r }
      if changed.contains(id) { rows.update(id, view, width) }
    }
  }

  /// The rows on screen with their distance from the viewport's top (Telegram's `visibleItems`).
  func visibleSnapshot() -> [(id: ID, fromTop: CGFloat)] {
    guard !heights.isEmpty else { return [] }
    let top = scrollY + clipHeight
    var out: [(ID, CGFloat)] = []
    for slot in heights.indices {
      let r = rect(ofSlot: slot)
      if r.maxY <= scrollY || r.minY >= top { continue }
      out.append((id(atSlot: slot), top - r.maxY))
    }
    return out
  }

  /// Puts the first row of the snapshot that is still in the window back where it was on screen.
  func saveVisible(_ snapshot: [(id: ID, fromTop: CGFloat)], timing: TimelineTiming = .none) {
    for entry in snapshot {
      guard let slot = slot(of: entry.id) else { continue }
      let r = rect(ofSlot: slot)
      let wanted = r.maxY + entry.fromTop - clipHeight
      let delta = wanted - scrollY
      if abs(delta) > 0.001 {
        setClip(wanted, preserving: true)
        if timing.isAnimated, window != nil { addDocumentTrack(timing, from: 0) }
      }
      return
    }
  }

  /// A new window [lo, hi) in one grouped update, the reader's row kept where it shows.
  func slide(lo newLo: Int, hi newHi: Int) {
    guard newLo != lo || newHi != hi else { return }
    let snapshot = visibleSnapshot()
    lo = max(0, newLo)
    hi = min(all.count, newHi)
    stats.edgeMoves += 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    relayoutWindow()
    saveVisible(snapshot)
    realise()
    CATransaction.commit()
  }

  func setClip(_ y: CGFloat, preserving: Bool) {
    let old = scrollY
    stats.clipMoves += 1
    if isLiveScrolling { stats.clipMovesWhileLive += 1 }
    isAdjusting = true
    clip.scroll(to: NSPoint(x: 0, y: y))
    scrollView.reflectScrolledClipView(clip)
    isAdjusting = false
    if preserving { preservingShift += scrollY - old }
    if abs(scrollY - y) > 0.01 { stats.clamps += 1 }
    lastScrollY = scrollY
  }

  func addDocumentTrack(_ timing: TimelineTiming, from delta: CGFloat) {
    guard let layer = document.layer, let animation = timing.animation(keyPath: "position.y", from: delta) else { return }
    trackSerial &+= 1
    layer.add(animation, forKey: "windowed.track.\(trackSerial)")
  }

  // MARK: - Scrolling

  @objc func boundsChanged(_ note: Notification) {
    guard !isAdjusting else { return }
    let began = CACurrentMediaTime()
    let y = scrollY
    if abs(y - lastScrollY) > 0.01 { direction = y > lastScrollY ? .older : .newer }
    lastScrollY = y
    // As NSTableView tiles: rows entering the visible or prepared rect now, synchronously.
    realise()
    // Bookkeeping (paging) once per run-loop turn.
    if !bookkeepingQueued {
      bookkeepingQueued = true
      RunLoop.main.perform(inModes: [.common]) { [weak self] in
        MainActor.assumeIsolated {
          self?.bookkeepingQueued = false
          self?.bookkeeping()
        }
      }
    }
    stats.follows += 1
    stats.followSeconds += CACurrentMediaTime() - began
  }

  @objc func liveStarted(_ note: Notification) { isLiveScrolling = true }
  @objc func liveEnded(_ note: Notification) {
    isLiveScrolling = false
    bookkeeping()
  }

  func prepare(_ rect: NSRect) {
    stats.prepares += 1
    prepared = rect
    stats.maxOverdrawAbove = max(stats.maxOverdrawAbove, rect.maxY - (scrollY + clipHeight))
    stats.maxOverdrawBelow = max(stats.maxOverdrawBelow, scrollY - rect.minY)
    realise()
  }

  /// Rows intersecting the visible rect or AppKit's prepared rect get a view; others go back.
  func realise() {
    guard !heights.isEmpty else { return }
    var wanted = NSRect(x: 0, y: scrollY, width: width, height: clipHeight)
    if !prepared.isEmpty { wanted = wanted.union(prepared) }
    let lowY = wanted.minY
    let highY = wanted.maxY
    // Slots are bottom-up; binary search the first slot whose top is above lowY.
    var a = 0
    var b = heights.count
    while a < b {
      let m = (a + b) / 2
      if spacer + bottoms[m] + heights[m] <= lowY { a = m + 1 } else { b = m }
    }
    var keep = Set<ID>()
    var slot = a
    while slot < heights.count, spacer + bottoms[slot] < highY {
      let id = id(atSlot: slot)
      keep.insert(id)
      let r = rect(ofSlot: slot)
      if let view = views[id] {
        if view.frame != r { view.frame = r }
      } else {
        let view = rows.make(id, width)
        view.frame = r
        if view.superview !== document { document.addSubview(view) }
        views[id] = view
        stats.makes += 1
      }
      slot += 1
    }
    for (id, view) in views where !keep.contains(id) {
      views[id] = nil
      view.removeFromSuperview()
      rows.recycle(id, view)
      stats.recycles += 1
    }
  }

  /// Near a window edge: a new window anchored on the edge row on screen (at most every 50 ms); at a loaded edge
  /// that is not the chat's, a demand for history.
  func bookkeeping() {
    guard !heights.isEmpty else { return }
    let snapshot = visibleSnapshot()
    guard let topRow = snapshot.first?.id, let bottomRow = snapshot.last?.id,
          let topSlot = slot(of: topRow), let bottomSlot = slot(of: bottomRow) else { return }
    let reach = max(1, (hi - lo) / 6)
    let now = CACurrentMediaTime()
    // Older side: rows above the top visible one in the window.
    let aboveInWindow = heights.count - 1 - topSlot
    let belowInWindow = bottomSlot
    var demands: Set<TimelineEdge> = []
    if aboveInWindow <= reach {
      if lo > 0 {
        if now - lastMerge >= 0.05, direction != .newer {
          lastMerge = now
          // Keep what shows and `reach` rows below it; the rest of the window goes ahead, above.
          let newHi = min(all.count, indexOf[bottomRow]! + 1 + reach)
          slide(lo: max(0, newHi - windowSize), hi: newHi)
        }
      } else if !coverage.reachesOldest {
        demands.insert(.older)
      }
    }
    if belowInWindow <= reach {
      if hi < all.count {
        if now - lastMerge >= 0.05, direction != .older {
          lastMerge = now
          let newLo = max(0, indexOf[topRow]! - reach)
          slide(lo: newLo, hi: min(all.count, newLo + windowSize))
        }
      } else if !coverage.reachesNewest {
        demands.insert(.newer)
      }
    }
    if !demands.isEmpty { onDemand?(demands) }
  }

  // MARK: - Programmatic scrolls (Telegram: within a screen animate from the presented bounds; farther, start one
  // screen before the target)

  func scrollTo(_ id: ID, alignment: TimelineAlignment, animated: Bool) {
    guard let index = indexOf[id] else { return }
    if index < lo || index >= hi {
      let newLo = max(0, min(index - windowSize / 2, all.count - windowSize))
      slide(lo: newLo, hi: min(all.count, newLo + windowSize))
    }
    guard let slot = slot(of: id) else { return }
    let r = rect(ofSlot: slot)
    let usable = clipHeight - topInset - spacer
    // The clip origin that puts the row where asked: its top `fromTop` below the clip's top edge.
    let fromTop: CGFloat = switch alignment {
      case let .top(distance): topInset + distance
      case .center: topInset + max(0, (usable - r.height) / 2)
      case let .bottom(distance): clipHeight - spacer - distance - r.height
    }
    let target = max(0, min(documentHeight - clipHeight + topInset, r.maxY + fromTop - clipHeight))
    if animated { animateScroll(to: target) } else { setClip(target, preserving: false) }
  }

  func animateScroll(to target: CGFloat) {
    let distance = target - scrollY
    if abs(distance) > clipHeight {
      setClip(target - (distance > 0 ? clipHeight : -clipHeight), preserving: false)
    }
    // AppKit's own animated clip scroll covers the last screen (0.35 s, Telegram's curve).
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.35
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 1.133, 1.0, 1.0)
      clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
    }
  }

  override public func layout() {
    super.layout()
    if scrollView.frame != bounds { scrollView.frame = bounds }
    scrollView.layoutSubtreeIfNeeded()
    if abs(clip.bounds.width - width) > 0.01, !all.isEmpty {
      // A new width: every window row re-measured; the reader's row kept where it shows.
      let snapshot = visibleSnapshot()
      relayoutWindow()
      if isAtBottom { setClip(0, preserving: false) } else { saveVisible(snapshot) }
      realise()
    } else {
      realise()
    }
  }
}
