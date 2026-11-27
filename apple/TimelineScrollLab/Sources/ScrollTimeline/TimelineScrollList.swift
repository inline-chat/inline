import AppKit
import QuartzCore
import TimelineCore

// A prototype of the macOS message list in a stock NSScrollView.
//
// The pure core (TimelineState and its solver) still decides which rows exist and where, relative to the reading row,
// with exact heights and no global content height. The scroll view only scrolls: responsive scrolling stays on (no
// `scrollWheel(with:)` override anywhere), momentum, elasticity and the scroller are the system's.
//
// Coordinates. Everything lives in one space, the clip view's ("clip space"): the document view's bounds origin equals
// its frame origin, so a row's frame in the document is its clip-space frame, and the clip's bounds origin `B` is the
// scroll position. The state's viewport y maps to clip space by `base`, the clip-space y of the viewport's top edge
// for the state's layout: clip y = viewport y + base. A scroll changes `B`; the state follows by `.by(base - B)` and
// `base = B`, so every placed row keeps its clip-space frame and nothing is moved but the clip.
//
// The document is a window of clip space around the placed rows: a reserve of empty space beyond rows that are not a
// loaded end, and an edge exactly at a loaded end once it is within reach (its rows measured), so the native bounce
// happens there. Moving the document's edges changes only its frame (and bounds origin to match), never `B` nor any
// row, so the scroll view's own position (which responsive scrolling holds off the main thread) is never fought.
// `B` moves only for what the reader did not do: pinning through an arrival, insets, jumps, and a rest-time re-centre
// that keeps clip space near zero for Core Animation's float precision.

/// How the list gets its rows. Heights are exact and synchronous; the list asks only for rows near the viewport.
@MainActor
public struct ScrollListRows<ID: Hashable & Sendable> {
  public var height: (ID, CGFloat) -> CGFloat
  public var make: (ID, CGFloat) -> NSView
  public var update: (ID, NSView, CGFloat) -> Void
  public var recycle: (ID, NSView) -> Void
  /// The row's sticky avatar, if it holds one (a group's last row): where it rests in the row, and its span.
  public var pin: ((ID, CGFloat) -> ScrollListPin<ID>?)?
  /// Where a span starting at this row begins, from the row's top.
  public var spanTop: (ID) -> CGFloat = { _ in 0 }
  /// The last row of the span this row belongs to, when that row holds the pin: kept placed while the span shows.
  public var spanEnd: ((ID) -> ID?)?
  /// A view for an avatar, and its content for a span.
  public var makePin: (() -> NSView)?
  public var configurePin: ((NSView, ID) -> Void)?

  public init(
    height: @escaping (ID, CGFloat) -> CGFloat, make: @escaping (ID, CGFloat) -> NSView,
    update: @escaping (ID, NSView, CGFloat) -> Void = { _, _, _ in }, recycle: @escaping (ID, NSView) -> Void = { _, _ in }
  ) {
    self.height = height
    self.make = make
    self.update = update
    self.recycle = recycle
  }
}

/// A sticky avatar: a list-owned view (not part of the row) that rests at its place in the group's last row, is lifted
/// to the visible bottom edge while that place is below it, and never goes above its span's top. It lives in one of
/// two containers (Telegram's design): the document while it rests or is held at its span's top (it scrolls with the
/// content, on whatever thread scrolls it), an overlay fixed to the viewport while it is lifted to the edge. It changes
/// container only at those crossings, on the main thread; between them nothing moves it.
public struct ScrollListPin<ID: Hashable & Sendable> {
  /// Its bottom at rest and its height, from the row's top; its x and width in the row.
  public var bottom: CGFloat
  public var height: CGFloat
  public var x: CGFloat
  public var width: CGFloat
  /// The row its span (the sender's group) starts in.
  public var spanStart: ID

  public init(bottom: CGFloat, height: CGFloat, x: CGFloat, width: CGFloat, spanStart: ID) {
    self.bottom = bottom
    self.height = height
    self.x = x
    self.width = width
    self.spanStart = spanStart
  }
}

/// The floating date: the section of the topmost row, pushed up by the next section's own row, hidden where its own row
/// shows (`TimelineHeaderFloat`), shown while moving and for `idleDelay` after.
@MainActor
public struct ScrollListHeader<ID: Hashable & Sendable> {
  public enum Host { case floatingSubview, overlay }
  public var view: NSView
  public var height: CGFloat
  public var gap: CGFloat
  public var section: (ID) -> ID?
  public var configure: (NSView, ID) -> Void
  public var idleDelay: TimeInterval
  public var host: Host

  public init(
    view: NSView, height: CGFloat, gap: CGFloat = 0, section: @escaping (ID) -> ID?,
    configure: @escaping (NSView, ID) -> Void, idleDelay: TimeInterval = 2, host: Host = .floatingSubview
  ) {
    self.view = view
    self.height = height
    self.gap = gap
    self.section = section
    self.configure = configure
    self.idleDelay = idleDelay
    self.host = host
  }
}

/// A pass-through, flipped view over the list (overlay avatars, an overlay header).
public final class ScrollListOverlay: NSView {
  nonisolated override public var isFlipped: Bool { true }
  override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One change to the list, resolved in one pass.
public struct ScrollListTransaction<ID: Hashable & Sendable> {
  public var rows: [ID]?
  public var coverage: TimelineCoverage?
  public var scroll: TimelineScroll<ID>
  public var topInset: CGFloat?
  public var bottomInset: CGFloat?
  public var changed: Set<ID>
  /// Animated changes move the content on the render server from where it showed (additive track on the document's
  /// layer); `.to` / `.latest` with a timing scroll there through the clip view instead.
  public var timing: TimelineTiming

  public init(
    rows: [ID]? = nil, coverage: TimelineCoverage? = nil, scroll: TimelineScroll<ID> = .preserve,
    topInset: CGFloat? = nil, bottomInset: CGFloat? = nil, changed: Set<ID> = [], timing: TimelineTiming = .none
  ) {
    self.rows = rows
    self.coverage = coverage
    self.scroll = scroll
    self.topInset = topInset
    self.bottomInset = bottomInset
    self.changed = changed
    self.timing = timing
  }
}

public struct ScrollListStats: Sendable {
  /// Layout passes (state apply + realisation), and their time in all (seconds).
  public var performs = 0
  public var performSeconds: Double = 0
  /// Of which: following the clip view's scroll.
  public var follows = 0
  public var followSeconds: Double = 0
  public var makes = 0
  public var recycles = 0
  /// Document edge moves (reserve grown, end snapped), and rest-time re-centres of clip space.
  public var edgeMoves = 0
  public var recentres = 0
  /// Programmatic clip moves (pinning, insets, jumps) and how many happened while the reader was scrolling.
  public var clipMoves = 0
  public var clipMovesWhileLive = 0
  /// `prepareContent(in:)` calls and the largest overdraw seen beyond the visible rect (above, below).
  public var prepares = 0
  public var maxOverdrawAbove: CGFloat = 0
  public var maxOverdrawBelow: CGFloat = 0
  /// Times the scroll view's position was found clamped against an edge the list just moved.
  public var clamps = 0
}

/// The document view: flipped, its bounds origin kept equal to its frame origin (clip space), compatible with
/// responsive scrolling, and preparing rows for the overdraw AppKit asks for.
public final class TimelineScrollDocument: NSView {
  nonisolated override public var isFlipped: Bool { true }
  override public class var isCompatibleWithResponsiveScrolling: Bool { true }
  /// Asked with AppKit's proposed overdraw; returns the rect to prepare (the list may add the rows it realised).
  var onPrepare: ((NSRect) -> NSRect)?

  override public func prepareContent(in rect: NSRect) {
    super.prepareContent(in: onPrepare?(rect) ?? rect)
  }
}

/// The system scroller showing the core's indicator instead of the document's geometry (which is a window of clip
/// space, not the chat).
public final class TimelineScroller: NSScroller {
  /// The place and knob proportion to show; nil shows what the scroll view sets.
  var shown: (value: Double, proportion: CGFloat)? {
    didSet {
      guard let shown else { return }
      if abs(super.doubleValue - shown.value) > 0.0005 { super.doubleValue = shown.value }
      if abs(super.knobProportion - shown.proportion) > 0.0005 { super.knobProportion = shown.proportion }
    }
  }

  /// A knob drag: the place the reader dragged to.
  var onDrag: ((Double) -> Void)?

  override public var doubleValue: Double {
    get { super.doubleValue }
    set { super.doubleValue = shown?.value ?? newValue }
  }

  override public var knobProportion: CGFloat {
    get { super.knobProportion }
    set { super.knobProportion = shown?.proportion ?? newValue }
  }

  override public func sendAction(_ action: Selector?, to target: Any?) -> Bool {
    // A knob or track click: the scroll view would map it onto the document (clip space); the list maps it onto the
    // chat instead.
    if let onDrag, hitPart == .knob || hitPart == .knobSlot {
      onDrag(super.doubleValue)
      return true
    }
    return super.sendAction(action, to: target)
  }
}

@MainActor
public final class TimelineScrollList<ID: Hashable & Sendable>: NSView {
  public let scrollView = NSScrollView()
  public let document = TimelineScrollDocument()
  public var clip: NSClipView { scrollView.contentView }
  public let scroller = TimelineScroller()
  /// Fixed to the viewport, over the scroll view: avatars lifted to the edge, an overlay header.
  public let overlay = ScrollListOverlay()
  public var floatingHeader: ScrollListHeader<ID>? {
    didSet {
      oldValue?.view.removeFromSuperview()
      headerSection = nil
      guard let header = floatingHeader else { return }
      header.view.wantsLayer = true
      header.view.alphaValue = 0
      switch header.host {
        case .floatingSubview: scrollView.addFloatingSubview(header.view, for: .vertical)
        case .overlay: overlay.addSubview(header.view)
      }
    }
  }
  /// Avatars by span (a group's first row), and where each lives.
  var pinViews: [ID: (view: NSView, inOverlay: Bool, row: ID)] = [:]
  var pinPool: [NSView] = []
  var headerSection: ID?
  var headerHide: DispatchWorkItem?
  /// The last time anything moved the content (for the floating date's idle hide).
  var lastMotion: CFTimeInterval = 0
  public var rows: ScrollListRows<ID>

  public var onDemand: ((Set<TimelineEdge>) -> Void)?
  public var onLayout: ((TimelineLayout<ID>) -> Void)?
  public private(set) var stats = ScrollListStats()

  /// Empty clip space kept beyond rows that are not a loaded end, and the least left before it is grown.
  public var reserve: CGFloat = 40_000
  public var lowWater: CGFloat = 8_000
  /// A loaded end within this many rows of the placed window is measured and becomes the document's edge.
  public var endReach = 160
  /// Rest-time re-centre once clip space has drifted this far from zero.
  public var recentreDistance: CGFloat = 200_000
  /// Rows realised beyond the overdraw AppKit asks for.
  public var minimumMargin: CGFloat = 200
  /// Realise rows ahead of the motion by its speed (0.12 s of travel, up to 1.5 screens), and keep every realised row
  /// inside the prepared rect so AppKit draws it before it scrolls in. Off: only what AppKit's overdraw asks for.
  public var leadsMotion = true
  /// The content's speed from the clip's moves (pt/s, positive: content moving down, towards older rows).
  public private(set) var velocity: CGFloat = 0
  var lastFollow: CFTimeInterval = 0

  var state: TimelineState<ID>
  var views: [ID: NSView] = [:]
  /// Clip-space y of the viewport's top for the state's layout.
  var base: CGFloat = 0
  var insets: (top: CGFloat, bottom: CGFloat) = (0, 0)
  /// The list is moving the clip or the document itself: bounds changes are its own.
  var isAdjusting = false
  var isPerforming = false
  public private(set) var isLiveScrolling = false
  var beforeFirstLayout: [ScrollListTransaction<ID>] = []
  var lastWidth: CGFloat = 0
  /// The overdraw AppKit last asked for, in clip space.
  var prepared: NSRect = .zero
  var indicator = TimelineIndicator(progress: 1)
  var indicatorProportion: CGFloat = 1
  /// An animated scroll through the clip view (a jump to a row, to the latest).
  var glide: Glide?
  var link: CADisplayLink?
  var trackSerial = 0

  struct Glide {
    var start: CFTimeInterval
    var duration: CFTimeInterval
    var target: TimelineScroll<ID>
    /// Clip travel to cover in all, and what has been applied.
    var travel: CGFloat
    var applied: CGFloat = 0
  }

  public var timelineLayout: TimelineLayout<ID> { state.layout }
  public var position: TimelinePosition<ID> { state.position }
  public var rowIDs: [ID] { state.rows }
  public var topInset: CGFloat { insets.top }
  public var bottomInset: CGFloat { insets.bottom }
  public var demandThreshold: Int {
    get { state.demandThreshold }
    set { state.demandThreshold = newValue }
  }

  nonisolated override public var isFlipped: Bool { true }

  public init(rows: ScrollListRows<ID>) {
    self.rows = rows
    state = TimelineState(viewport: TimelineViewport(width: 0, height: 0))
    super.init(frame: .zero)
    state.demandThreshold = 40
    wantsLayer = true
    scrollView.wantsLayer = true
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.verticalScroller = scroller
    scrollView.verticalScrollElasticity = .allowed
    scrollView.horizontalScrollElasticity = .none
    scrollView.usesPredominantAxisScrolling = true
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsetsZero
    scrollView.autohidesScrollers = true
    clip.drawsBackground = false
    clip.postsBoundsChangedNotifications = true
    document.wantsLayer = true
    document.onPrepare = { [weak self] rect in self?.prepare(rect) ?? rect }
    scrollView.documentView = document
    addSubview(scrollView)
    overlay.wantsLayer = true
    addSubview(overlay)
    scroller.onDrag = { [weak self] value in self?.dragIndicator(to: value) }
    NotificationCenter.default.addObserver(
      self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(liveScrollStarted(_:)), name: NSScrollView.willStartLiveScrollNotification,
      object: scrollView
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(liveScrollEnded(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView
    )
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError() }

  isolated deinit {
    NotificationCenter.default.removeObserver(self)
    link?.invalidate()
  }

  // MARK: - Public

  public func apply(_ transaction: ScrollListTransaction<ID>) {
    if let top = transaction.topInset { insets.top = top }
    if let bottom = transaction.bottomInset { insets.bottom = bottom }
    guard clip.bounds.width > 0, clip.bounds.height > 0 else {
      var waiting = transaction
      waiting.timing = .none
      beforeFirstLayout.append(waiting)
      return
    }
    // Insets that grow go in first; insets that shrink go in after the clip has moved: a smaller inset makes AppKit
    // clamp the clip at once, which would drop the content before the change could animate it.
    syncInsets(onlyGrowing: true)
    if transaction.scroll != .preserve { stopGlide() }
    let glides: Bool = switch transaction.scroll {
      case .to, .latest: transaction.timing.isAnimated && window != nil
      case .preserve, .by: false
    }
    var update = TimelineUpdate<ID>(
      rows: transaction.rows, coverage: transaction.coverage, viewport: viewport(),
      scroll: glides ? .preserve : transaction.scroll
    )
    if isLiveScrolling {
      update.followsBottomInset = false
      update.pinsWhenAtBottom = false
      update.allowsOverscroll = true
    }
    perform(update, changed: transaction.changed, timing: glides ? .none : transaction.timing)
    syncInsets()
    if glides { startGlide(to: transaction.scroll, timing: transaction.timing) }
  }

  public func setInsets(top: CGFloat? = nil, bottom: CGFloat? = nil, timing: TimelineTiming = .none) {
    apply(ScrollListTransaction(topInset: top, bottomInset: bottom, timing: timing))
  }

  public func view(for id: ID) -> NSView? { views[id] }
  public var placedViews: [(ID, NSView)] { views.map { ($0.key, $0.value) } }

  /// The row's settled frame in this view's coordinates.
  public func frame(for id: ID) -> CGRect? {
    state.layout.placement(for: id).map { CGRect(x: 0, y: $0.y, width: bounds.width, height: $0.height) }
  }

  /// The clip view's scroll position as the render server shows it now (clip space).
  public var presentedScrollPosition: CGFloat {
    guard let layer = clip.layer else { return clip.bounds.origin.y }
    let clipY = (layer.presentation() ?? layer).bounds.origin.y
    // An additive track on the document (an animated change) moves the content without the clip.
    guard let docLayer = document.layer else { return clipY }
    let model = docLayer.position.y
    let shown = (docLayer.presentation() ?? docLayer).position.y
    return clipY - (shown - model)
  }

  /// Where the row shows now, in this view's coordinates.
  public func presentedFrame(for id: ID) -> CGRect? {
    guard let view = views[id] else { return nil }
    let y = view.frame.minY - presentedScrollPosition
    return CGRect(x: 0, y: y, width: view.frame.width, height: view.frame.height)
  }

  /// The clip view's model scroll position (clip space).
  public var scrollPosition: CGFloat { clip.bounds.origin.y }
  public var documentFrame: NSRect { document.frame }
  public var preparedRect: NSRect { prepared }
  public var isMoving: Bool { isLiveScrolling || glide != nil }

  /// Diagnostics: whether AppKit considers this scroll view eligible for concurrent (responsive) scrolling.
  public var isConcurrentScrollingCompatible: Bool? {
    let selector = NSSelectorFromString("_isConcurrentScrollingCompatible")
    guard scrollView.responds(to: selector), let method = scrollView.method(for: selector) else { return nil }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(method, to: Getter.self)(scrollView, selector)
  }

  // MARK: - Layout

  override public func layout() {
    super.layout()
    if scrollView.frame != bounds { scrollView.frame = bounds }
    if overlay.frame != bounds { overlay.frame = bounds }
    scrollView.layoutSubtreeIfNeeded()
    let viewport = viewport()
    guard viewport.width > 0, viewport.height > 0 else { return }
    syncInsets()
    if !beforeFirstLayout.isEmpty {
      let waiting = beforeFirstLayout
      beforeFirstLayout = []
      for transaction in waiting { apply(transaction) }
    }
    if viewport != state.viewport {
      var update = TimelineUpdate<ID>(viewport: viewport)
      if isLiveScrolling {
        update.followsBottomInset = false
        update.pinsWhenAtBottom = false
        update.allowsOverscroll = true
      }
      perform(update, changed: [], timing: .none)
    }
  }

  func viewport() -> TimelineViewport {
    TimelineViewport(
      width: clip.bounds.width, height: clip.bounds.height, topInset: insets.top, bottomInset: insets.bottom
    )
  }

  func syncInsets(onlyGrowing: Bool = false) {
    let current = scrollView.contentInsets
    var wanted = NSEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
    if onlyGrowing {
      wanted.top = max(wanted.top, current.top)
      wanted.bottom = max(wanted.bottom, current.bottom)
    }
    guard current.top != wanted.top || current.bottom != wanted.bottom else { return }
    let origin = clip.bounds.origin
    isAdjusting = true
    scrollView.contentInsets = wanted
    // AppKit may move the clip to keep the content under the old inset; the list decides where it goes.
    if clip.bounds.origin != origin { clip.setBoundsOrigin(origin) }
    isAdjusting = false
  }

  /// Realise rows for the overdraw AppKit prepares (responsive scrolling draws ahead into it); returns the rect to
  /// prepare: AppKit's, plus every realised row when the list leads the motion.
  func prepare(_ rect: NSRect) -> NSRect {
    stats.prepares += 1
    prepared = rect
    let top = clip.bounds.origin.y
    let bottom = top + clip.bounds.height
    stats.maxOverdrawAbove = max(stats.maxOverdrawAbove, top - rect.minY)
    stats.maxOverdrawBelow = max(stats.maxOverdrawBelow, rect.maxY - bottom)
    let margins = wantedMargins()
    if !isPerforming, margins != state.margins {
      state.margins = margins
      var update = TimelineUpdate<ID>()
      update.followsBottomInset = false
      update.pinsWhenAtBottom = false
      update.allowsOverscroll = true
      perform(update, changed: [], timing: .none)
    }
    return leadsMotion ? rect.union(realisedRect) : rect
  }

  /// The rows realised, in clip space (the document's bounds).
  var realisedRect: NSRect {
    guard let first = state.layout.placements.first, let last = state.layout.placements.last else { return .zero }
    return NSRect(x: 0, y: first.y + base, width: clip.bounds.width, height: last.maxY - first.y)
  }

  func wantedMargins() -> TimelineMargins {
    let top = clip.bounds.origin.y
    let height = clip.bounds.height
    let bottom = top + height
    var above = minimumMargin
    var below = minimumMargin
    let cap = max(minimumMargin, height * 1.5)
    if !prepared.isEmpty {
      above = max(above, min(cap, top - prepared.minY + 40))
      below = max(below, min(cap, prepared.maxY - bottom + 40))
    }
    if leadsMotion, isLiveScrolling || glide != nil {
      let lead = min(cap, abs(velocity) * 0.12 + minimumMargin)
      if velocity > 0 { above = max(above, lead) } else { below = max(below, lead) }
    }
    return TimelineMargins(above: above.rounded(.up), below: below.rounded(.up))
  }

  // MARK: - Following the scroll

  @objc func clipBoundsChanged(_ note: Notification) {
    guard !isAdjusting else { return }
    follow()
  }

  // MARK: - Sticky avatars and the floating date

  /// Every placed row's avatar where the core's pin geometry puts it, in the document (at rest or held at its span's
  /// top: it scrolls with the content) or in the overlay (lifted to the edge: fixed to the viewport).
  /// A view's top as shown now, in this view's coordinates.
  func shownY(of view: NSView) -> CGFloat? {
    guard let target = view.layer, let mine = layer else { return nil }
    let from = target.presentation() ?? target
    let to = mine.presentation() ?? mine
    return from.convert(from.bounds, to: to).minY
  }

  func updatePins(_ layout: TimelineLayout<ID>, timing: TimelineTiming, shown: [ID: CGFloat], documentMoved: CGFloat) {
    guard let pinOf = rows.pin, let first = layout.placements.first else {
      for (_, entry) in pinViews { retirePin(entry.view) }
      pinViews = [:]
      return
    }
    let width = layout.viewport.width
    let edge = layout.viewport.usableBottom
    var seen = Set<ID>()
    for placement in layout.placements {
      guard let pin = pinOf(placement.id, width) else { continue }
      // A span starting above the placed rows starts above the screen: it does not limit.
      var spanTop = -CGFloat.infinity
      if let index = state.index[pin.spanStart], index >= first.index, index - first.index < layout.placements.count {
        let start = layout.placements[index - first.index]
        spanTop = start.y + rows.spanTop(start.id)
      }
      let rest = placement.y + pin.bottom
      let geometry = TimelinePinGeometry(bottom: rest, height: pin.height, spanTop: spanTop, edge: edge)
      let lift = geometry.lift
      let lifted = lift > 0.001 && lift < geometry.maxLift - 0.001
      seen.insert(pin.spanStart)
      var entry = pinViews[pin.spanStart]
      if entry == nil {
        let view = pinPool.popLast() ?? rows.makePin?() ?? NSView()
        view.wantsLayer = true
        rows.configurePin?(view, pin.spanStart)
        entry = (view, !lifted, placement.id)
      }
      guard var entry else { continue }
      let view = entry.view
      if lifted {
        // Fixed to the viewport, bottom on the edge.
        if view.superview !== overlay { overlay.addSubview(view) }
        view.frame = NSRect(x: pin.x, y: edge - pin.height, width: pin.width, height: pin.height)
      } else {
        // In the document, at rest or held at the span's top: rides with the content.
        if view.superview !== document { document.addSubview(view) }
        view.frame = NSRect(x: pin.x, y: rest - lift - pin.height + base, width: pin.width, height: pin.height)
      }
      entry.inOverlay = lifted
      entry.row = placement.id
      pinViews[pin.spanStart] = entry
      // Animated: an avatar already on screen starts where it showed and moves to its new place on the change's timing
      // (in the document the content's own track already carries it by `documentMoved`).
      if timing.isAnimated, let before = shown[pin.spanStart] {
        let settled = lifted ? view.frame.minY : view.frame.minY - clip.bounds.origin.y
        let from = before - settled - (lifted ? 0 : documentMoved)
        if abs(from) > 0.01, let animation = timing.animation(keyPath: "position.y", from: from) {
          trackSerial &+= 1
          view.layer?.add(animation, forKey: "scrolllist.pin.\(trackSerial)")
        }
      }
    }
    for (span, entry) in pinViews where !seen.contains(span) {
      retirePin(entry.view)
      pinViews[span] = nil
    }
  }

  func retirePin(_ view: NSView) {
    view.removeFromSuperview()
    if pinPool.count < 16 { pinPool.append(view) }
  }

  /// Avatars on screen, by the row holding each, with the view.
  public var pinnedViews: [(ID, NSView)] { pinViews.values.map { ($0.row, $0.view) } }

  /// The floating date where `TimelineHeaderFloat` puts it; shown while moving and for its idle delay after.
  func updateHeader(_ layout: TimelineLayout<ID>, moved: Bool) {
    guard let header = floatingHeader else { return }
    if moved { lastMotion = CACurrentMediaTime() }
    let place = TimelineHeaderFloat.place(in: layout, height: header.height, gap: header.gap, section: header.section)
    guard let place else {
      header.view.alphaValue = 0
      return
    }
    if place.section != headerSection {
      headerSection = place.section
      header.configure(header.view, place.section)
    }
    switch header.host {
      case .floatingSubview:
        // A vertical floating subview does not scroll vertically; its y is measured from below the top content inset
        // (found: placed at the layout's y it showed exactly the toolbar's 52 pt too low).
        header.view.frame = NSRect(x: 0, y: place.y - insets.top, width: layout.viewport.width, height: header.height)
      case .overlay:
        header.view.frame = NSRect(x: 0, y: place.y, width: layout.viewport.width, height: header.height)
    }
    let showing = isMoving || CACurrentMediaTime() - lastMotion < header.idleDelay
    header.view.alphaValue = showing ? 1 : 0
    if moved {
      headerHide?.cancel()
      let work = DispatchWorkItem { [weak self] in
        MainActor.assumeIsolated {
          guard let self, let header = self.floatingHeader, !self.isMoving else { return }
          NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            header.view.animator().alphaValue = 0
          }
        }
      }
      headerHide = work
      DispatchQueue.main.asyncAfter(deadline: .now() + header.idleDelay, execute: work)
    }
  }

  @objc func liveScrollStarted(_ note: Notification) {
    isLiveScrolling = true
    stopGlide()
  }

  @objc func liveScrollEnded(_ note: Notification) {
    isLiveScrolling = false
    // At rest: pin if resting on the newest row, and re-centre clip space if it drifted far.
    var update = TimelineUpdate<ID>()
    update.allowsOverscroll = false
    perform(update, changed: [], timing: .none)
    recentreIfFar()
  }

  /// The clip moved (the reader, momentum, the bounce, AppKit clamping): the state follows.
  func follow() {
    let origin = clip.bounds.origin.y
    let delta = origin - base
    guard abs(delta) > 0.0001, !isPerforming else { return }
    let began = CACurrentMediaTime()
    let since = began - lastFollow
    if lastFollow > 0, since > 0.001, since < 0.1 {
      velocity = 0.6 * velocity + 0.4 * (-delta / CGFloat(since))
    } else {
      velocity = 0
    }
    lastFollow = began
    indicator.move(by: -delta, extent: indicatorExtent())
    base = origin
    var update = TimelineUpdate<ID>(scroll: .by(-delta))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    update.allowsOverscroll = true
    perform(update, changed: [], timing: .none, follows: true)
    stats.follows += 1
    stats.followSeconds += CACurrentMediaTime() - began
  }

  // MARK: - Perform

  func perform(_ update: TimelineUpdate<ID>, changed: Set<ID>, timing: TimelineTiming, follows: Bool = false) {
    guard !isPerforming else { return }
    // The clip may have moved since the last bounds notification (responsive scrolling moves it from its own thread and
    // tells the main thread later): follow it first, or the base below would put it back where it was.
    if !follows, abs(clip.bounds.origin.y - base) > 0.0001 { follow() }
    isPerforming = true
    defer {
      isPerforming = false
      // AppKit clamped the clip into a moved document, or a clip move did not land: follow where it is.
      if abs(clip.bounds.origin.y - base) > 0.0001 { follow() }
    }
    let began = CACurrentMediaTime()
    var update = update
    if update.viewport == nil { update.viewport = viewport() }
    state.margins = wantedMargins()
    let width = update.viewport!.width
    let previous = state.layout
    let oldBase = base
    let spanEnd = rows.spanEnd
    let change = state.apply(update, spanEnd: { spanEnd?($0) }) { [rows] in rows.height($0, width) }
    let layout = change.layout

    // Keep a surviving row's clip-space place: the reading row if it survived, else the lowest survivor. A scroll the
    // list follows already moved the base with the clip.
    if !follows {
      var previousY: [ID: CGFloat] = [:]
      for placement in previous.placements { previousY[placement.id] = placement.y }
      let reading: ID? = if case let .row(id, _) = layout.position { id } else { layout.placements.last?.id }
      let reference = reading.flatMap { id in previousY[id] != nil ? layout.placement(for: id) : nil }
        ?? layout.placements.last { previousY[$0.id] != nil }
      if let reference, let old = previousY[reference.id] {
        base = old + oldBase - reference.y
      } else {
        // Nothing survived (a far jump, the first rows): the destination shows where the clip is.
        base = clip.bounds.origin.y
      }
    }

    // Where each avatar shows before this change, for an animated change to start it from there.
    var pinsShown: [ID: CGFloat] = [:]
    if timing.isAnimated, window != nil {
      for (span, entry) in pinViews {
        if let y = shownY(of: entry.view) { pinsShown[span] = y }
      }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    realise(layout, changed: changed, width: width)
    moveEdges(layout)
    // Every realised row inside the prepared rect: AppKit draws a view only inside it (or the visible rect), so a row
    // realised ahead of the motion is drawn before it shows.
    if leadsMotion {
      let wanted = document.visibleRect.union(realisedRect)
      if wanted != document.preparedContentRect { document.preparedContentRect = wanted }
    }
    let clipDelta = base - clip.bounds.origin.y
    if abs(clipDelta) > 0.0001 {
      moveClip(to: base)
      // Animated: what showed starts where it was and moves with the change's timing (the composer's spring, an
      // arrival rising), on the render server, as the content's own track.
      if timing.isAnimated, window != nil { addDocumentTrack(timing, from: clipDelta) }
    }
    updateIndicator(change)
    updatePins(layout, timing: timing.isAnimated && window != nil ? timing : .none, shown: pinsShown, documentMoved: clipDelta)
    updateHeader(layout, moved: follows || abs(clipDelta) > 0.0001)
    CATransaction.commit()

    stats.performs += 1
    stats.performSeconds += CACurrentMediaTime() - began
    if !change.demands.isEmpty { onDemand?(change.demands) }
    onLayout?(layout)
  }

  func realise(_ layout: TimelineLayout<ID>, changed: Set<ID>, width: CGFloat) {
    var placed = Set<ID>()
    placed.reserveCapacity(layout.placements.count)
    let widthChanged = abs(width - lastWidth) > 0.01
    lastWidth = width
    for placement in layout.placements {
      placed.insert(placement.id)
      let frame = NSRect(x: 0, y: placement.y + base, width: width, height: placement.height)
      if let view = views[placement.id] {
        let resized = abs(view.frame.height - frame.height) > 0.01 || widthChanged
        if view.frame != frame { view.frame = frame }
        if resized || changed.contains(placement.id) { rows.update(placement.id, view, width) }
      } else {
        let view = rows.make(placement.id, width)
        view.frame = frame
        // Rows go to the bottom of the document's order: avatars riding in the document stay above them.
        if view.superview !== document { document.addSubview(view, positioned: .below, relativeTo: nil) }
        views[placement.id] = view
        stats.makes += 1
      }
    }
    for (id, view) in views where !placed.contains(id) {
      views[id] = nil
      view.removeFromSuperview()
      rows.recycle(id, view)
      stats.recycles += 1
    }
  }

  /// The document's edges: at a loaded end within reach (measured), else a reserve beyond the placed rows. Only the
  /// document's frame moves (its bounds origin with it), never the clip nor a row.
  func moveEdges(_ layout: TimelineLayout<ID>) {
    guard let first = layout.placements.first, let last = layout.placements.last else { return }
    let width = layout.viewport.width
    let topY = first.y + base
    let bottomY = last.maxY + base
    var frame = document.frame
    var docTop = frame.minY
    var docBottom = frame.maxY
    let usable = layout.viewport.usableHeight

    // Rows beyond the placed window up to a loaded end, when it is near.
    let aboveCount = first.index
    let belowCount = state.rows.count - 1 - last.index
    var oldestTop: CGFloat?
    var newestBottom: CGFloat?
    if aboveCount <= endReach {
      var sum: CGFloat = 0
      for index in 0 ..< aboveCount { sum += max(0, rows.height(state.rows[index], width)) }
      oldestTop = topY - sum
    }
    if belowCount <= endReach {
      var sum: CGFloat = 0
      for index in (last.index + 1) ..< state.rows.count { sum += max(0, rows.height(state.rows[index], width)) }
      newestBottom = bottomY + sum
    }

    if let oldestTop, let newestBottom, newestBottom - oldestTop <= usable {
      // Shorter than the usable area: it rests on the usable bottom, with nothing to scroll.
      docBottom = newestBottom
      docTop = newestBottom - usable
    } else {
      if let oldestTop {
        docTop = oldestTop
      } else if topY - docTop < lowWater || topY - docTop > reserve * 3 {
        docTop = topY - reserve
      }
      if let newestBottom {
        docBottom = newestBottom
      } else if docBottom - bottomY < lowWater || docBottom - bottomY > reserve * 3 {
        docBottom = bottomY + reserve
      }
    }
    frame.origin.y = docTop
    frame.size.height = max(1, docBottom - docTop)
    frame.size.width = width
    frame.origin.x = 0
    guard frame != document.frame else { return }
    stats.edgeMoves += 1
    let origin = clip.bounds.origin
    isAdjusting = true
    document.frame = frame
    document.setBoundsOrigin(frame.origin)
    if clip.bounds.origin != origin { stats.clamps += 1 }
    isAdjusting = false
  }

  func moveClip(to y: CGFloat) {
    stats.clipMoves += 1
    if isLiveScrolling { stats.clipMovesWhileLive += 1 }
    isAdjusting = true
    clip.scroll(to: NSPoint(x: 0, y: y))
    scrollView.reflectScrolledClipView(clip)
    isAdjusting = false
    if abs(clip.bounds.origin.y - y) > 0.01 { stats.clamps += 1 }
  }

  /// At rest, far from zero: everything moves by the same amount in clip space, so nothing on screen does.
  func recentreIfFar() {
    let origin = clip.bounds.origin.y
    guard abs(origin) > recentreDistance, !isLiveScrolling, glide == nil else { return }
    let shift = -origin.rounded()
    stats.recentres += 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    isAdjusting = true
    for view in views.values { view.frame.origin.y += shift }
    var frame = document.frame
    frame.origin.y += shift
    document.frame = frame
    document.setBoundsOrigin(frame.origin)
    base += shift
    clip.scroll(to: NSPoint(x: 0, y: origin + shift))
    scrollView.reflectScrolledClipView(clip)
    isAdjusting = false
    CATransaction.commit()
  }

  func addDocumentTrack(_ timing: TimelineTiming, from delta: CGFloat) {
    // The clip moved by `delta` (content up by delta on screen); the content starts where it showed: lower by delta.
    guard let layer = document.layer, let animation = timing.animation(keyPath: "position.y", from: delta) else { return }
    trackSerial &+= 1
    layer.add(animation, forKey: "scrolllist.track.\(trackSerial)")
  }

  // MARK: - Animated scrolls through the clip view

  func startGlide(to target: TimelineScroll<ID>, timing: TimelineTiming) {
    guard let travel = travel(to: target) else {
      perform(TimelineUpdate(viewport: viewport(), scroll: target), changed: [], timing: .none)
      return
    }
    glide = Glide(start: CACurrentMediaTime(), duration: max(0.2, timing.duration), target: target, travel: travel)
    if link == nil {
      let link = displayLink(target: self, selector: #selector(tick(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
    }
    link?.isPaused = false
  }

  func stopGlide() {
    glide = nil
    link?.isPaused = true
  }

  /// Clip travel from here to the target, from measured rows; nil when it is too far to measure (lands at once).
  func travel(to target: TimelineScroll<ID>) -> CGFloat? {
    let layout = state.layout
    let viewport = layout.viewport
    let width = viewport.width
    guard let anchor = layout.placements.last else { return nil }
    let ids = state.rows
    func top(of index: Int) -> CGFloat? {
      // The row's top in viewport coordinates, measured from the last placed row.
      if abs(index - anchor.index) > 2000 { return nil }
      var y = anchor.y
      if index >= anchor.index {
        for i in anchor.index ..< index { y += rows.height(ids[i], width) }
      } else {
        for i in index ..< anchor.index { y -= rows.height(ids[i], width) }
      }
      return y
    }
    switch target {
      case .latest:
        guard let top = top(of: ids.count - 1) else { return nil }
        let bottom = top + rows.height(ids[ids.count - 1], width)
        return bottom - viewport.usableBottom
      case let .to(id, alignment):
        guard let index = state.index[id], let rowTop = top(of: index) else { return nil }
        let height = rows.height(id, width)
        let wanted: CGFloat = switch alignment {
          case let .top(distance): viewport.usableTop + distance
          case .center: viewport.usableTop + max(0, (viewport.usableHeight - height) / 2)
          case let .bottom(distance): viewport.usableBottom - distance - height
        }
        return rowTop - wanted
      case .preserve, .by:
        return nil
    }
  }

  @objc func tick(_ link: CADisplayLink) {
    guard var glide else {
      link.isPaused = true
      return
    }
    let t = min(1, (link.targetTimestamp - glide.start) / glide.duration)
    // Ease out (cubic), as NSClipView's animated scrolls.
    let eased = 1 - pow(1 - t, 3)
    let wanted = glide.travel * CGFloat(eased)
    let step = wanted - glide.applied
    glide.applied = wanted
    self.glide = glide
    if abs(step) > 0.0001 {
      // Through the clip view, as the reader's scroll: the state follows from the bounds change.
      clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + step))
      scrollView.reflectScrolledClipView(clip)
    }
    if t >= 1 {
      let target = glide.target
      stopGlide()
      // Land exactly (the measured travel and the solver agree unless rows changed on the way).
      perform(TimelineUpdate(viewport: viewport(), scroll: target), changed: [], timing: .none)
    }
  }

  // MARK: - Indicator

  func indicatorExtent() -> TimelineIndicator.Extent {
    state.layout.indicatorExtent(rowCount: state.rows.count, coverage: state.coverage, unknown: 2 * max(1, state.viewport.usableHeight))
  }

  func updateIndicator(_ change: TimelineChange<ID>) {
    let extent = indicatorExtent()
    if change.isDisjoint || change.previous.placements.isEmpty {
      indicator = TimelineIndicator(progress: TimelineIndicator.estimate(extent))
    }
    if !isLiveScrolling || indicatorProportion == 1 {
      indicatorProportion = extent.total > 0 ? max(0.05, min(1, extent.visible / extent.total)) : 1
    }
    scroller.shown = (Double(indicator.progress), indicatorProportion)
  }

  /// The knob dragged (or the track clicked) to a place: move there through the chat, as the knob's place maps.
  func dragIndicator(to value: Double) {
    let extent = indicatorExtent()
    let from = indicator.progress
    let to = CGFloat(min(1, max(0, value)))
    var delta: CGFloat = 0
    if to < from, from > 0 {
      delta = extent.above * (1 - to / from)
    } else if to > from, from < 1 {
      delta = -extent.below * (1 - (1 - to) / (1 - from))
    }
    guard abs(delta) > 0.5 else { return }
    indicator = TimelineIndicator(progress: to)
    var update = TimelineUpdate<ID>(viewport: viewport(), scroll: .by(delta))
    update.pinsWhenAtBottom = false
    perform(update, changed: [], timing: .none)
  }
}

extension TimelineTiming {
  var duration: CFTimeInterval {
    switch self {
      case .none: 0
      case let .spring(_, _, _, duration): CFTimeInterval(duration)
      case let .curve(duration, _, _, _, _): CFTimeInterval(duration)
    }
  }

  /// An additive animation of `keyPath` from `delta` to zero.
  func animation(keyPath: String, from delta: CGFloat) -> CAAnimation? {
    guard abs(delta) > 0.01 else { return nil }
    switch self {
      case .none:
        return nil
      case let .spring(mass, stiffness, damping, duration):
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = mass
        spring.stiffness = stiffness
        spring.damping = damping
        spring.duration = CFTimeInterval(duration)
        spring.fromValue = delta
        spring.toValue = 0
        spring.isAdditive = true
        spring.fillMode = .backwards
        return spring
      case let .curve(duration, c1x, c1y, c2x, c2y):
        let basic = CABasicAnimation(keyPath: keyPath)
        basic.duration = CFTimeInterval(duration)
        basic.timingFunction = CAMediaTimingFunction(controlPoints: c1x, c1y, c2x, c2y)
        basic.fromValue = delta
        basic.toValue = 0
        basic.isAdditive = true
        basic.fillMode = .backwards
        return basic
    }
  }
}
