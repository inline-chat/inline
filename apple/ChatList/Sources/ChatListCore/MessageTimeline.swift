import CoreGraphics
import Foundation

/// All occlusions use upright document coordinates. Insets belong to the plan;
/// the native scroll view must not also add them to its contentInsets.
public struct TimelineViewport: Equatable, Sendable {
  public var width: CGFloat
  public var height: CGFloat
  public var topInset: CGFloat
  public var bottomInset: CGFloat

  public init(width: CGFloat, height: CGFloat, topInset: CGFloat = 0, bottomInset: CGFloat = 0) {
    self.width = Self.finite(width)
    self.height = Self.finite(height)
    self.topInset = Self.finite(topInset)
    self.bottomInset = Self.finite(bottomInset)
  }

  public var readingHeight: CGFloat {
    max(0, height - topInset - bottomInset)
  }

  private static func finite(_ value: CGFloat) -> CGFloat {
    value.isFinite ? max(0, value) : 0
  }
}

/// Stable, local row identity is deliberately independent of a server message ID.
/// Element frames allow a renderer to advance message internals on the list clock.
public struct TimelineRow<ID: Hashable & Sendable>: Equatable, Sendable {
  public var id: ID
  public var height: CGFloat
  public var elements: [String: CGRect]
  public var canAnchor: Bool

  public init(id: ID, height: CGFloat, elements: [String: CGRect] = [:], canAnchor: Bool = true) {
    self.id = id
    self.height = height.isFinite ? max(0, height) : 0
    self.elements = elements
    self.canAnchor = canAnchor
  }
}

public enum TimelineAnchorEdge: Equatable, Sendable { case top, bottom }

public struct TimelineAnchor<ID: Hashable & Sendable>: Equatable, Sendable {
  public var id: ID
  /// Position inside a row, optionally resolved from a prepared text coordinate.
  public var localY: CGFloat
  /// Distance inward from the unobscured viewport edge (down from top, up from bottom).
  public var viewportY: CGFloat
  public var edge: TimelineAnchorEdge

  public init(id: ID, localY: CGFloat = 0, viewportY: CGFloat = 0, edge: TimelineAnchorEdge = .top) {
    self.id = id
    self.localY = localY
    self.viewportY = viewportY
    self.edge = edge
  }

  public func viewportPosition(in viewport: TimelineViewport) -> CGFloat {
    switch edge {
      case .top: viewport.topInset + viewportY
      case .bottom: viewport.height - viewport.bottomInset - viewportY
    }
  }
}

public enum TimelineIntent<ID: Hashable & Sendable>: Equatable, Sendable {
  case latest
  case reading(TimelineAnchor<ID>)
}

/// Where a row is in its lifecycle on the presented frame. Cells use the
/// progress to drive their own insertion or removal effects on the list clock.
public enum ChatListRowPhase: Equatable, Sendable {
  case present
  case entering(progress: CGFloat, insertion: ChatListInsertion)
  case exiting(progress: CGFloat, removal: ChatListRemoval)
}

/// Immutable presentation geometry. Range lookup is O(log n + visible rows).
public struct TimelineLayout<ID: Hashable & Sendable>: Sendable {
  public struct Placement: Sendable {
    public var row: TimelineRow<ID>
    /// Presented frame, including move offsets and a lifted reorder row.
    public var frame: CGRect
    public var opacity: CGFloat
    public var isExiting: Bool
    public var phase: ChatListRowPhase = .present
    /// Lifted by a reorder gesture; hosts draw it above other rows.
    public var isReordering = false
    /// Slot in the row flow. Anchors and range lookups use it.
    public var flowFrame: CGRect
    /// Waiting outside a far jump's target screen; not shown until it settles.
    public var isSuppressed = false
  }

  public let rows: [Placement]
  public let viewport: TimelineViewport
  public let contentHeight: CGFloat
  public let originY: CGFloat
  /// The lifted row while a reorder is active.
  public let reorderingID: ID?
  /// Rows from the previous screen sliding out during a far jump. Their frames
  /// are unrelated to their flow slots, so hosts keep them resident explicitly.
  public let departingIDs: Set<ID>
  /// Largest distance between a presented frame and its flow slot.
  let offsetReach: CGFloat
  private let indices: [ID: Int]

  init(
    rows: [Placement], viewport: TimelineViewport, contentHeight: CGFloat, originY: CGFloat,
    reorderingID: ID? = nil, departingIDs: Set<ID> = [], offsetReach: CGFloat = 0
  ) {
    self.rows = rows
    self.viewport = viewport
    self.contentHeight = contentHeight
    self.originY = originY
    self.reorderingID = reorderingID
    self.departingIDs = departingIDs
    self.offsetReach = offsetReach
    indices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.row.id, $0.offset) })
  }

  private init(copying layout: Self, originY: CGFloat) {
    rows = layout.rows
    viewport = layout.viewport
    contentHeight = layout.contentHeight
    indices = layout.indices
    reorderingID = layout.reorderingID
    departingIDs = layout.departingIDs
    offsetReach = layout.offsetReach
    self.originY = originY
  }

  public func scrolled(to origin: CGFloat, nativeOverscroll: Bool = false) -> Self {
    Self(copying: self, originY: nativeOverscroll ? origin : min(maximumOrigin, max(0, origin)))
  }

  public var maximumOrigin: CGFloat {
    max(0, contentHeight - viewport.height)
  }

  public var readingRect: CGRect {
    CGRect(x: 0, y: originY + viewport.topInset, width: viewport.width, height: viewport.readingHeight)
  }

  public func placement(for id: ID) -> Placement? {
    indices[id].map { rows[$0] }
  }

  public func index(for id: ID) -> Int? {
    indices[id]
  }

  /// Rows whose presented frame may intersect `rect`. Includes rows whose move
  /// offset carries them in from outside their flow slot.
  public func visibleRows(in rect: CGRect) -> Range<Int> {
    flowRows(in: offsetReach > 0 ? rect.insetBy(dx: 0, dy: -offsetReach) : rect)
  }

  /// Rows whose flow slot intersects `rect`.
  func flowRows(in rect: CGRect) -> Range<Int> {
    var lower = 0
    var upper = rows.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if rows[middle].flowFrame.maxY <= rect.minY {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    let first = lower
    while lower < rows.count, rows[lower].flowFrame.minY < rect.maxY {
      lower += 1
    }
    return first ..< lower
  }

  public func anchor(at origin: CGFloat? = nil, edge: TimelineAnchorEdge = .top) -> TimelineAnchor<ID>? {
    let top = (origin ?? originY) + viewport.topInset
    let range = flowRows(in: CGRect(x: 0, y: top, width: 1, height: max(1, viewport.readingHeight)))
    if edge == .bottom {
      guard let row = rows[range].last(where: { !$0.isExiting && $0.row.canAnchor && $0.row.height > 0 })
        ?? rows.last(where: { !$0.isExiting && $0.row.canAnchor }) else { return nil }
      let bottom = (origin ?? originY) + viewport.height - viewport.bottomInset
      let localY = min(row.flowFrame.height, max(0, bottom - row.flowFrame.minY))
      return .init(id: row.row.id, localY: localY,
                   viewportY: bottom - row.flowFrame.minY - localY, edge: .bottom)
    }
    guard let row = rows[range].first(where: { !$0.isExiting && $0.row.canAnchor && $0.row.height > 0 })
      ?? rows.last(where: { !$0.isExiting && $0.row.canAnchor }) else { return nil }
    return TimelineAnchor(id: row.row.id, localY: top - row.flowFrame.minY)
  }

  /// Presented frame in viewport coordinates (Telegram's `updateAbsoluteRect`).
  public func viewportFrame(for id: ID) -> CGRect? {
    placement(for: id).map { $0.frame.offsetBy(dx: 0, dy: -originY) }
  }

  /// Share of the row inside the usable viewport (Telegram's item visibility).
  public func visibility(for id: ID) -> ChatListRowVisibility {
    guard let placement = placement(for: id) else { return .hidden }
    return visibility(of: placement)
  }

  func visibility(of placement: Placement) -> ChatListRowVisibility {
    guard !placement.isExiting, !placement.isSuppressed, placement.frame.height > 0 else { return .hidden }
    let visible = placement.frame.intersection(readingRect)
    guard !visible.isNull, visible.height > 0 else { return .hidden }
    return .visible(
      fraction: min(1, visible.height / placement.frame.height),
      rect: visible.offsetBy(dx: 0, dy: -originY)
    )
  }

  /// Rows inside the usable viewport, oldest first.
  public var visibleRange: ChatListVisibleRange<ID> {
    let reading = readingRect
    var ids: [ID] = []
    var full: [ID] = []
    for placement in rows[visibleRows(in: reading)] {
      guard case let .visible(fraction, _) = visibility(of: placement) else { continue }
      ids.append(placement.row.id)
      if fraction >= 0.999 { full.append(placement.row.id) }
    }
    return .init(ids: ids, fullyVisible: full)
  }
}

private struct TimelineRectMotion: Sendable {
  var x: TimelineSpring
  var y: TimelineSpring
  var width: TimelineSpring
  var height: TimelineSpring

  init(_ frame: CGRect) {
    x = .init(frame.minX)
    y = .init(frame.minY)
    width = .init(frame.width)
    height = .init(frame.height)
  }

  var frame: CGRect {
    CGRect(x: x.value, y: y.value, width: max(0, width.value), height: max(0, height.value))
  }

  var isSettled: Bool {
    x.isSettled && y.isSettled && width.isSettled && height.isSettled
  }

  mutating func set(_ frame: CGRect, motion: ChatListMotion?) {
    x.set(frame.minX, motion: motion)
    y.set(frame.minY, motion: motion)
    width.set(frame.width, motion: motion)
    height.set(frame.height, motion: motion)
  }

  mutating func advance(_ dt: Double) {
    x.advance(dt)
    y.advance(dt)
    width.advance(dt)
    height.advance(dt)
  }
}

private struct TimelineOverlayOffset: Sendable {
  var x: TimelineSpring
  var y: TimelineSpring

  init(_ offset: CGPoint) {
    x = .init(offset.x)
    y = .init(offset.y)
    x.target = 0
    y.target = 0
  }

  var offset: CGPoint {
    CGPoint(x: x.value, y: y.value)
  }

  var isSettled: Bool {
    x.isSettled && y.isSettled
  }

  mutating func retarget(from offset: CGPoint) {
    // Retain both velocities when an edit interrupts an earlier handoff.
    x.value = offset.x
    y.value = offset.y
    x.target = 0
    y.target = 0
  }

  mutating func advance(_ dt: Double) {
    x.advance(dt)
    y.advance(dt)
  }
}

/// A value-only presentation owner. Neither AppKit nor cells can measure or
/// independently invalidate its geometry. The host installs each result once.
public struct MessageTimeline<ID: Hashable & Sendable>: Sendable {
  private struct Motion: Sendable {
    var id: ID
    var canAnchor: Bool
    var height: TimelineSpring
    var opacity: TimelineSpring
    /// Visual displacement from the flow slot, for moves and reorder drops.
    var offset = TimelineSpring(0)
    var elements: [String: TimelineRectMotion]
    var presentedElements: [String: CGRect]
    var exiting = false
    var entering: ChatListInsertion?
    var removal: ChatListRemoval = .collapse
    var exitHeight: CGFloat = 0
    /// Screen position when a far jump began, for a row sliding out with it.
    var departing: Departing?
    var isSettled: Bool {
      height.isSettled && opacity.isSettled && offset.isSettled && elements.values.allSatisfy(\.isSettled)
    }
  }

  private struct Departing: Sendable {
    var screenY: CGFloat
    var height: CGFloat
  }

  /// A far jump, as Telegram's `temporaryPreviousNodes`: the old screen and the
  /// new one travel together, so nothing vanishes and only one screen is crossed.
  private struct Entry: Sendable {
    var offset: TimelineSpring
    var start: CGFloat
    /// New rows beyond the target screen on the side the old rows occupy.
    var hidesBelow: CGFloat?
    var hidesAbove: CGFloat?
  }

  private struct ScreenRow: Sendable {
    var id: ID
    var screenY: CGFloat
    var height: CGFloat
  }

  private struct Reorder: Sendable {
    var id: ID
    /// Touch distance below the lifted row's top, in viewport coordinates.
    var grab: CGFloat
    var touchY: CGFloat
    var origin: CGFloat
    var originalIndex: Int
    var originalLiveIndex: Int
    var bounds: ClosedRange<Int>
    var lastHop: Double
    var speed: CGFloat = 0
    var scrollStart: Double?
  }

  /// Telegram moves a lifted row at most once per 0.2 s.
  static var reorderHopInterval: Double { 0.2 }
  /// Telegram scrolls while the lifted row's center is within 10 pt of an edge,
  /// by 6 pt per frame at 60 Hz, half again as fast after 2 s.
  static var reorderEdgeZone: CGFloat { 10 }
  static var reorderScrollSpeed: CGFloat { 360 }

  public private(set) var intent: TimelineIntent<ID> = .latest
  /// Increments each time an explicit navigation reaches its target.
  public private(set) var navigationCompletions: UInt64 = 0
  /// Increments each time a lifted row changes its slot.
  public private(set) var reorderHops: UInt64 = 0
  private var overlayOffsets: [Int64: TimelineOverlayOffset] = [:]
  private var overlayOpacities: [Int64: TimelineSpring] = [:]
  public private(set) var layout: TimelineLayout<ID>
  private var motions: [Motion] = []
  private var viewport: TimelineViewport
  private var top: TimelineSpring
  private var bottom: TimelineSpring
  private var clock: Double?
  private var navigation: TimelineSpring?
  private var reorder: Reorder?
  private var entry: Entry?
  /// AppKit owns rubber-band physics. Carry its transient displacement through
  /// concurrent geometry changes without converting it into a durable anchor.
  private var nativeOverscroll: CGFloat = 0

  public init(viewport: TimelineViewport) {
    self.viewport = viewport
    top = .init(viewport.topInset)
    bottom = .init(viewport.bottomInset)
    layout = TimelineLayout(rows: [], viewport: viewport, contentHeight: viewport.height, originY: 0)
  }

  public var targetViewport: TimelineViewport {
    viewport
  }

  public var isNavigating: Bool {
    navigation != nil || entry != nil
  }

  public var isReordering: Bool {
    reorder != nil
  }

  /// Bottom motion keeps ownership until it settles, even if a toolbar also
  /// changes during the keyboard transition. Explicit navigation still wins.
  public func anchorEdge(for next: TimelineViewport) -> TimelineAnchorEdge {
    if next.bottomInset != viewport.bottomInset || !bottom.isSettled { return .bottom }
    if next.topInset != viewport.topInset { return .top }
    if case let .reading(anchor) = intent { return anchor.edge }
    return .bottom
  }

  public var isAnimating: Bool {
    !top.isSettled || !bottom.isSettled || navigation != nil || entry != nil || motions.contains { !$0.isSettled || $0.exiting }
      || overlayOffsets.values.contains { !$0.isSettled } || overlayOpacities.values.contains { !$0.isSettled }
      || (reorder?.speed ?? 0) != 0
  }

  /// An overlay may change its owning row while its row geometry is already
  /// settled. Keep that correction on the same analytic clock as the rows.
  public func overlayOffset(for id: Int64) -> CGPoint {
    overlayOffsets[id]?.offset ?? .zero
  }

  public mutating func retargetOverlayOffset(for id: Int64, from offset: CGPoint, animated: Bool) {
    guard animated, offset.x.isFinite, offset.y.isFinite else {
      overlayOffsets.removeValue(forKey: id)
      return
    }
    if var existing = overlayOffsets[id] {
      existing.retarget(from: offset)
      overlayOffsets[id] = existing
    } else if abs(offset.x) >= 0.01 || abs(offset.y) >= 0.01 {
      overlayOffsets[id] = TimelineOverlayOffset(offset)
    }
  }

  public mutating func retainOverlayOffsets(for ids: Set<Int64>) {
    overlayOffsets = overlayOffsets.filter { ids.contains($0.key) }
  }

  public func overlayOpacity(for id: Int64) -> CGFloat {
    overlayOpacities[id]?.value ?? 1
  }

  public func isOverlayOpacitySettled(for id: Int64) -> Bool {
    overlayOpacities[id]?.isSettled ?? true
  }

  public mutating func retargetOverlayOpacity(for id: Int64, from value: CGFloat, to target: CGFloat) {
    guard value.isFinite, target.isFinite else { return }
    let start = min(1, max(0, value))
    let end = min(1, max(0, target))
    var opacity = overlayOpacities[id] ?? TimelineSpring(start)
    opacity.value = start
    opacity.set(end, animated: true)
    if opacity.isSettled, end == 1 {
      overlayOpacities.removeValue(forKey: id)
    } else {
      overlayOpacities[id] = opacity
    }
  }

  public mutating func retainOverlayOpacity(for ids: Set<Int64>) {
    overlayOpacities = overlayOpacities.filter { ids.contains($0.key) }
  }

  public mutating func removeOverlayMotion(for id: Int64) {
    overlayOffsets.removeValue(forKey: id)
    overlayOpacities.removeValue(forKey: id)
  }

  /// Inputs are a complete, prepared snapshot, never estimated row heights.
  public mutating func apply(
    rows: [TimelineRow<ID>], viewport: TimelineViewport,
    intent requestedIntent: TimelineIntent<ID>? = nil, animated: Bool, at time: Double
  ) {
    apply(rows: rows, viewport: viewport, intent: requestedIntent,
          motion: animated ? .system : nil, at: time)
  }

  /// One transaction for inserts, removals, height and inset changes, intent,
  /// and an optional directional entry for a far jump into a new window.
  public mutating func apply(
    rows: [TimelineRow<ID>], viewport: TimelineViewport,
    intent requestedIntent: TimelineIntent<ID>? = nil, motion: ChatListMotion?,
    transitions: ChatListTransitions<ID> = .init(),
    entering direction: ChatListScrollDirection? = nil, at time: Double
  ) {
    let lag = catchUpLag(at: time)
    let insetsWereSettled = (top.isSettled, bottom.isSettled)
    // A far jump replaces the window: rows appear in place and the whole
    // content slides in, instead of every row growing from zero height.
    let transitions = direction == nil || requestedIntent == nil ? transitions : ChatListTransitions(
      insertion: .none, removal: .none, insertions: transitions.insertions,
      removals: transitions.removals, animatesMoves: false
    )
    advance(to: time)
    if reorder != nil { settleReorder(motion: motion) }
    let isFarJump = direction != nil && requestedIntent != nil && motion != nil
    let previousScreenRows = isFarJump ? screenRows() : []
    let previousOriginForJump = layout.originY
    if isFarJump { clearEntry() }
    if requestedIntent == nil {
      retainPresentedAnchorBeforeRetargeting()
      retainInsetAnchor(for: viewport)
    }
    precondition(Set(rows.map(\.id)).count == rows.count, "Timeline identities must be unique")
    let previous = layout
    let previousScreen = transitions.animatesMoves && motion != nil ? screenPositions() : [:]
    let targets = Set(rows.map(\.id))
    if let requestedIntent {
      intent = requestedIntent
      navigation = nil
      clearEntry()
      nativeOverscroll = 0
    }
    if case let .reading(anchor) = intent, !targets.contains(anchor.id) {
      // Preserve a surviving neighbor at its actual screen position. Never use
      // total-height compensation, an old row index, or a scrollbar fraction.
      let oldIndex = previous.index(for: anchor.id) ?? 0
      let next = previous.rows.dropFirst(oldIndex).first { targets.contains($0.row.id) && $0.row.canAnchor }
        ?? previous.rows.prefix(oldIndex).last { targets.contains($0.row.id) && $0.row.canAnchor }
      if let next {
        let offset = anchor.edge == .top
          ? next.flowFrame.minY - previous.readingRect.minY
          : previous.originY + previous.viewport.height - previous.viewport.bottomInset - next.flowFrame.minY
        intent = .reading(.init(id: next.row.id, viewportY: offset, edge: anchor.edge))
      } else if let first = rows.first(where: \.canAnchor) {
        intent = .reading(.init(id: first.id))
      } else {
        intent = .latest
      }
    }

    let animated = motion != nil
    var prior = Dictionary(uniqueKeysWithValues: motions.map { ($0.id, $0) })
    var next: [Motion] = rows.map { row in
      if var existing = prior.removeValue(forKey: row.id) {
        existing.exiting = false
        existing.departing = nil
        existing.canAnchor = row.canAnchor
        existing.height.set(row.height, motion: motion)
        existing.opacity.set(1, motion: motion)
        existing.elements = row.elements.mapValues { frame in TimelineRectMotion(frame) }.merging(
          existing.elements.filter { row.elements[$0.key] != nil }
        ) { _, current in current }
        for (key, frame) in row.elements {
          existing.elements[key]?.set(frame, motion: motion)
        }
        existing.presentedElements = existing.elements.mapValues(\.frame)
        return existing
      }
      let insertion = animated ? transitions.insertion(for: row.id) : .none
      let grows = insertion == .grow || insertion == .reveal
      let fades = insertion == .grow || insertion == .fade
      var created = Motion(
        id: row.id, canAnchor: row.canAnchor, height: .init(grows ? 0 : row.height),
        opacity: .init(fades ? 0 : 1), elements: row.elements.mapValues(TimelineRectMotion.init),
        presentedElements: row.elements
      )
      created.entering = insertion == .none ? nil : insertion
      created.height.set(row.height, motion: motion)
      created.opacity.set(1, motion: motion)
      return created
    }
    if animated {
      // Bucket by the next old surviving neighbor in one reverse pass.
      // Repeated array insertion here made a large animated eviction quadratic.
      var before: [ID: [Motion]] = [:]
      var trailing: [Motion] = []
      var successor: ID?
      for old in motions.reversed() {
        if targets.contains(old.id) {
          successor = old.id
          continue
        }
        var exiting = old
        if let screen = previousScreenRows.first(where: { $0.id == old.id }) {
          // Stays where it is and travels with the new content.
          exiting.departing = .init(screenY: screen.screenY, height: screen.height)
          exiting.exiting = true
          exiting.entering = nil
          exiting.removal = .none
          exiting.exitHeight = screen.height
          exiting.height.set(0, motion: nil)
          exiting.opacity.set(1, motion: nil)
          if let successor { before[successor, default: []].append(exiting) }
          else { trailing.append(exiting) }
          continue
        }
        if !exiting.exiting {
          let removal = transitions.removal(for: old.id)
          if removal == .none { continue }
          exiting.removal = removal
          exiting.exitHeight = old.height.value
        }
        exiting.exiting = true
        exiting.entering = nil
        exiting.height.set(0, motion: motion)
        exiting.opacity.set(exiting.removal == .collapseOpaque ? 1 : 0, motion: motion)
        if let successor { before[successor, default: []].append(exiting) }
        else { trailing.append(exiting) }
      }
      var merged: [Motion] = []
      merged.reserveCapacity(next.count + motions.count - targets.intersection(Set(motions.map(\.id))).count)
      for motion in next {
        if let exits = before[motion.id] { merged.append(contentsOf: exits.reversed()) }
        merged.append(motion)
      }
      merged.append(contentsOf: trailing.reversed())
      next = merged
    }
    motions = next
    self.viewport = viewport
    // Exact-width/content commits may disable row motion without cancelling
    // an unrelated keyboard/composer transition already in flight.
    setInsets(for: viewport, motion: motion, lag: lag, wereSettled: insetsWereSettled)
    rebuild()
    if !previousScreen.isEmpty, let motion { animateMoves(from: previousScreen, motion: motion, excluding: nil) }
    if isFarJump, let motion,
       !beginEntry(from: previousScreenRows, previousOrigin: previousOriginForJump, direction: direction, motion: motion) {
      clearDeparting()
      rebuild()
    }
  }

  /// A native-owned viewport sample supersedes passive inset motion at its
  /// current presentation. Row and child motion can still advance independently.
  mutating func stopInsetMotionAtPresentation() {
    top.set(top.value, motion: nil)
    bottom.set(bottom.value, motion: nil)
  }

  public mutating func resize(
    viewport: TimelineViewport, animated: Bool, at time: Double,
    preservingNativeOrigin: Bool = false
  ) {
    resize(viewport: viewport, motion: animated ? .system : nil, at: time,
           preservingNativeOrigin: preservingNativeOrigin)
  }

  /// `time` is when the change started. A keyboard notification delivered
  /// after the display clock already advanced starts its inset motion in the
  /// past, so the list lands on the keyboard's own curve rather than a frame late.
  public mutating func resize(
    viewport: TimelineViewport, motion: ChatListMotion?, at time: Double,
    preservingNativeOrigin: Bool = false
  ) {
    let lag = catchUpLag(at: time)
    let insetsWereSettled = (top.isSettled, bottom.isSettled)
    if preservingNativeOrigin { stopInsetMotionAtPresentation() }
    if nativeOverscroll != 0 { advanceViewportDuringOverscroll(to: time) }
    else { advance(to: time) }
    let reachedOrigin = layout.originY
    if !preservingNativeOrigin { retainInsetAnchor(for: viewport) }
    self.viewport = viewport
    if preservingNativeOrigin {
      top.set(viewport.topInset, motion: nil)
      bottom.set(viewport.bottomInset, motion: nil)
    } else {
      setInsets(for: viewport, motion: motion, lag: lag, wereSettled: insetsWereSettled)
    }
    rebuild()
    // Rebase both the reading intent and rubber-band distance against the new
    // bounds. No intermediate rebuilt origin is published to the native host.
    if preservingNativeOrigin { userScrolled(to: reachedOrigin) }
  }

  private func catchUpLag(at time: Double) -> Double {
    guard time.isFinite, let clock else { return 0 }
    return max(0, clock - time)
  }

  private mutating func setInsets(
    for viewport: TimelineViewport, motion: ChatListMotion?, lag: Double, wereSettled: (Bool, Bool)
  ) {
    if top.target != viewport.topInset {
      top.set(viewport.topInset, motion: motion)
      if wereSettled.0, lag > 0 { top.advance(lag) }
    }
    if bottom.target != viewport.bottomInset {
      bottom.set(viewport.bottomInset, motion: motion)
      if wereSettled.1, lag > 0 { bottom.advance(lag) }
    }
  }

  public mutating func navigate(to intent: TimelineIntent<ID>, animated: Bool, at time: Double) {
    navigate(to: intent, motion: animated ? .system : nil, at: time)
  }

  /// Scroll to an intent. A nearby target scrolls there. Farther than one screen,
  /// or against a stated direction, the old and new screens slide together over
  /// about one screen. Retargeting a scroll in flight keeps position and velocity.
  public mutating func navigate(
    to intent: TimelineIntent<ID>, motion: ChatListMotion?,
    direction: ChatListScrollDirection? = nil, at time: Double
  ) {
    advance(to: time)
    guard reorder == nil else { return }
    let previousRows = screenRows()
    let previousOrigin = layout.originY
    let inFlight = navigation
    clearEntry()
    self.intent = intent
    nativeOverscroll = 0
    navigation = nil
    rebuild()
    guard let motion else { return }
    let distance = previousOrigin - layout.originY
    let cap = max(1, layout.viewport.readingHeight)
    let contradicts = direction.map { distance != 0 && ($0 == .up) != (distance > 0) } ?? false
    let isFar = abs(distance) > cap && (inFlight == nil || direction != nil)
    if (isFar || contradicts),
       beginEntry(from: previousRows, previousOrigin: previousOrigin, direction: direction, motion: motion) {
      return
    }
    // A repeated keyboard/jump request retargets the existing scroll spring.
    // Keep its presentation velocity just as row and inset springs do.
    var scroll = inFlight ?? TimelineSpring(previousOrigin)
    scroll.motion = Self.scrollMotion(motion)
    navigation = scroll
    rebuild()
  }

  /// Scroll uses a spring so repeated requests keep velocity.
  private static func scrollMotion(_ motion: ChatListMotion) -> ChatListMotion {
    if case .spring = motion { return motion }
    return .system
  }

  /// Rows on screen now, at their presented positions.
  private func screenRows() -> [ScreenRow] {
    let origin = layout.originY
    let screen = CGRect(x: 0, y: origin, width: layout.viewport.width, height: layout.viewport.height)
    return layout.rows.compactMap { placement in
      guard !placement.isSuppressed, placement.frame.height > 0, placement.opacity > 0,
            placement.frame.intersects(screen) else { return nil }
      return ScreenRow(id: placement.row.id, screenY: placement.frame.minY - origin, height: placement.frame.height)
    }
  }

  /// Start a far jump from a layout already rebuilt at its target. A row visible
  /// before and after anchors the motion; otherwise the new screen starts touching
  /// the old one on the far side, as Telegram places them.
  @discardableResult
  private mutating func beginEntry(
    from old: [ScreenRow], previousOrigin: CGFloat, direction: ChatListScrollDirection?, motion: ChatListMotion
  ) -> Bool {
    guard let oldTop = old.map(\.screenY).min(),
          let oldBottom = old.map({ $0.screenY + $0.height }).max() else { return false }
    let target = layout.originY
    let screen = CGRect(x: 0, y: target, width: layout.viewport.width, height: layout.viewport.height)
    var start: CGFloat?
    for row in old {
      if let placement = layout.placement(for: row.id), !placement.isExiting, placement.flowFrame.intersects(screen) {
        start = row.screenY - (placement.flowFrame.minY - target)
        break
      }
    }
    var entering = Entry(offset: .init(0), start: 0)
    if start == nil {
      let incoming = layout.rows[layout.flowRows(in: screen)].filter { !$0.isExiting && $0.flowFrame.height > 0 }
      guard let newTop = incoming.first?.flowFrame.minY, let newBottom = incoming.last?.flowFrame.maxY else { return false }
      let toward = direction ?? (previousOrigin > target ? .up : .down)
      if toward == .up {
        start = oldTop - (newBottom - target)
        entering.hidesBelow = newBottom
      } else {
        start = oldBottom - (newTop - target)
        entering.hidesAbove = newTop
      }
      for row in old {
        guard let index = motions.firstIndex(where: { $0.id == row.id }) else { continue }
        motions[index].departing = .init(screenY: row.screenY, height: row.height)
      }
    }
    guard let start else { return false }
    entering.start = start
    entering.offset = .init(start)
    entering.offset.set(0, motion: motion)
    entry = entering
    rebuild()
    return true
  }

  private mutating func clearEntry() {
    guard entry != nil else { return }
    entry = nil
    clearDeparting()
  }

  private mutating func clearDeparting() {
    for index in motions.indices { motions[index].departing = nil }
    motions.removeAll { $0.exiting && $0.isSettled }
  }

  /// Refine a reading coordinate after the renderer has installed this frame's
  /// child geometry. This does not advance springs or rebuild row placements.
  /// Native input and explicit navigation take precedence over this bridge.
  @discardableResult
  public mutating func refineReadingAnchor(_ anchor: TimelineAnchor<ID>) -> Bool {
    guard case .reading = intent, navigation == nil, entry == nil, nativeOverscroll == 0, reorder == nil,
          anchor.localY.isFinite, anchor.viewportY.isFinite,
          let row = layout.placement(for: anchor.id), !row.isExiting, row.row.canAnchor else { return false }
    var resolved = anchor
    resolved.localY = min(resolved.localY, row.flowFrame.height)
    intent = .reading(resolved)
    layout = layout.scrolled(
      to: row.flowFrame.minY + resolved.localY - resolved.viewportPosition(in: layout.viewport)
    )
    return true
  }

  /// Called before native wheel handling, then again with the reached origin.
  /// This revokes automatic follow intent before a synchronous update can run.
  public mutating func beginUserScroll(at origin: CGFloat) {
    navigation = nil
    if entry != nil {
      clearEntry()
      rebuild()
    }
    userScrolled(to: origin)
  }

  public mutating func userScrolled(to origin: CGFloat) {
    guard reorder == nil else { return }
    let clamped = min(layout.maximumOrigin, max(0, origin))
    nativeOverscroll = origin - clamped
    if let anchor = layout.anchor(at: clamped, edge: bottom.isSettled ? .top : .bottom) {
      intent = .reading(anchor)
    }
    layout = layout.scrolled(to: origin, nativeOverscroll: true)
  }

  public mutating func endUserScroll(at origin: CGFloat, canFollowLatest: Bool) {
    guard reorder == nil else { return }
    nativeOverscroll = 0
    if canFollowLatest, abs(layout.maximumOrigin - origin) <= 2 {
      intent = .latest
    } else if let anchor = layout.anchor(at: origin, edge: bottom.isSettled ? .top : .bottom) {
      intent = .reading(anchor)
    }
    layout = layout.scrolled(to: origin)
  }

  /// Rebase after AppKit's transient rubber-band phase without advancing the
  /// presentation springs by the time native geometry was deliberately held.
  public mutating func synchronizeClock(at time: Double) {
    if time.isFinite {
      clock = max(clock ?? time, time)
    }
  }

  /// Keyboard and toolbar motion stays live while native rubber-band physics
  /// owns scrolling. Hold row/child motion and rebase its clock so settlement
  /// does not consume the time spent bouncing in one frame.
  @discardableResult
  mutating func advanceViewportDuringOverscroll(to time: Double) -> Bool {
    guard time.isFinite, time >= (clock ?? time) else { return false }
    let dt = max(0, time - (clock ?? time))
    clock = time
    let previousTop = top.value
    let previousBottom = bottom.value
    top.advance(dt)
    bottom.advance(dt)
    guard top.value != previousTop || bottom.value != previousBottom else { return false }
    rebuild()
    return true
  }

  public mutating func advance(to time: Double) {
    guard time.isFinite else { return }
    // A boundary-time native callback may have already advanced presentation
    // beyond a captured transaction timestamp. Never count that time twice.
    if let clock, time < clock {
      return
    }
    let dt = max(0, time - (clock ?? time))
    clock = time
    top.advance(dt)
    bottom.advance(dt)
    for index in motions.indices where !motions[index].isSettled {
      motions[index].height.advance(dt)
      motions[index].opacity.advance(dt)
      motions[index].offset.advance(dt)
      for key in motions[index].elements.keys {
        motions[index].elements[key]?.advance(dt)
      }
      motions[index].presentedElements = motions[index].elements.mapValues(\.frame)
      if motions[index].entering != nil, motions[index].height.isSettled, motions[index].opacity.isSettled {
        motions[index].entering = nil
      }
    }
    for id in Array(overlayOffsets.keys) {
      guard var offset = overlayOffsets[id] else { continue }
      offset.advance(dt)
      if offset.isSettled {
        overlayOffsets.removeValue(forKey: id)
      } else {
        overlayOffsets[id] = offset
      }
    }
    for id in Array(overlayOpacities.keys) {
      guard var opacity = overlayOpacities[id] else { continue }
      opacity.advance(dt)
      if opacity.isSettled, opacity.target == 1 {
        overlayOpacities.removeValue(forKey: id)
      } else {
        overlayOpacities[id] = opacity
      }
    }
    motions.removeAll { $0.exiting && $0.isSettled && $0.departing == nil }
    navigation?.advance(dt)
    if var current = entry {
      current.offset.advance(dt)
      if current.offset.isSettled {
        clearEntry()
        navigationCompletions &+= 1
      } else {
        entry = current
      }
    }
    autoscrollReorder(dt, at: time)
    rebuild()
    if reorder != nil { updateReorderTarget(at: time) }
  }

  // MARK: Reordering

  /// Lift a row under a touch at `touchY` (viewport coordinates). The row can
  /// move within the contiguous run of neighbors that `canMove` accepts.
  @discardableResult
  public mutating func beginReorder(
    id: ID, touchY: CGFloat, at time: Double, canMove: (ID) -> Bool
  ) -> Bool {
    advance(to: time)
    guard reorder == nil, nativeOverscroll == 0, touchY.isFinite,
          let index = motions.firstIndex(where: { $0.id == id && !$0.exiting }),
          let placement = layout.placement(for: id), canMove(id) else { return false }
    var lower = index
    while lower > 0, !motions[lower - 1].exiting, canMove(motions[lower - 1].id) { lower -= 1 }
    var upper = index
    while upper < motions.count - 1, !motions[upper + 1].exiting, canMove(motions[upper + 1].id) { upper += 1 }
    navigation = nil
    if entry != nil {
      clearEntry()
      rebuild()
    }
    let origin = layout.originY
    let liveIndex = motions[..<index].filter { !$0.exiting }.count
    reorder = Reorder(
      id: id, grab: touchY - (placement.frame.minY - origin), touchY: touchY, origin: origin,
      originalIndex: index, originalLiveIndex: liveIndex, bounds: lower ... upper, lastHop: -.infinity
    )
    rebuild()
    return true
  }

  public mutating func updateReorder(touchY: CGFloat, at time: Double) {
    guard reorder != nil, touchY.isFinite else { return }
    advance(to: time)
    reorder?.touchY = touchY
    autoscrollReorder(0, at: time)
    rebuild()
    updateReorderTarget(at: time)
  }

  /// Drop the lifted row into its current slot. Returns the committed move.
  public mutating func endReorder(at time: Double) -> ChatListReorder<ID>? {
    advance(to: time)
    guard let current = reorder else { return nil }
    settleReorder(motion: .system)
    let live = motions.filter { !$0.exiting }.map(\.id)
    guard let toIndex = live.firstIndex(of: current.id) else { return nil }
    return ChatListReorder(
      id: current.id, fromIndex: current.originalLiveIndex, toIndex: toIndex,
      before: toIndex > 0 ? live[toIndex - 1] : nil,
      after: toIndex + 1 < live.count ? live[toIndex + 1] : nil
    )
  }

  /// Return the lifted row and its neighbors to their original order.
  public mutating func cancelReorder(at time: Double) {
    advance(to: time)
    guard let current = reorder, let index = motions.firstIndex(where: { $0.id == current.id }) else { return }
    if index != current.originalIndex, current.originalIndex < motions.count {
      let before = screenPositions()
      let lifted = motions.remove(at: index)
      motions.insert(lifted, at: min(current.originalIndex, motions.count))
      rebuild()
      animateMoves(from: before, motion: .system, excluding: current.id)
    }
    settleReorder(motion: .system)
  }

  /// Put the lifted row back in the flow from wherever it floats.
  private mutating func settleReorder(motion: ChatListMotion?) {
    guard let current = reorder else { return }
    let floating = layout.placement(for: current.id)?.frame.minY
    if let anchor = layout.anchor(at: current.origin) { intent = .reading(anchor) }
    reorder = nil
    rebuild()
    if let floating, let index = motions.firstIndex(where: { $0.id == current.id }),
       let slot = layout.placement(for: current.id)?.flowFrame.minY {
      motions[index].offset.value = floating - slot
      motions[index].offset.set(0, motion: motion)
      rebuild()
    }
  }

  private mutating func autoscrollReorder(_ dt: Double, at time: Double) {
    guard var current = reorder else { return }
    let center = current.touchY - current.grab + (layout.placement(for: current.id)?.frame.height ?? 0) / 2
    let topEdge = viewport.topInset + Self.reorderEdgeZone
    let bottomEdge = viewport.height - viewport.bottomInset - Self.reorderEdgeZone
    var direction: CGFloat = 0
    if center < topEdge, layout.originY > 0 { direction = -1 }
    else if center > bottomEdge, layout.originY < layout.maximumOrigin { direction = 1 }
    if direction == 0 {
      current.speed = 0
      current.scrollStart = nil
    } else {
      let start = current.scrollStart ?? time
      current.scrollStart = start
      current.speed = direction * Self.reorderScrollSpeed * (time - start > 2 ? 1.5 : 1)
      if dt > 0 {
        current.origin = min(layout.maximumOrigin, max(0, current.origin + current.speed * CGFloat(dt)))
      }
    }
    reorder = current
  }

  /// Telegram's rule: the nearest row edge to the lifted row's center decides
  /// the slot, on whichever side of that edge the center is.
  private mutating func updateReorderTarget(at time: Double) {
    guard let current = reorder,
          let index = motions.firstIndex(where: { $0.id == current.id }),
          let lifted = layout.placement(for: current.id) else { return }
    let center = lifted.frame.midY
    var closest: (slot: Int, offset: CGFloat)?
    for slot in current.bounds where slot < motions.count && motions[slot].id != current.id {
      guard let frame = layout.placement(for: motions[slot].id)?.flowFrame else { continue }
      let toMin = frame.minY - center
      let toMax = frame.maxY - center
      let offset = abs(toMin) > abs(toMax) ? toMax : toMin
      if closest == nil || abs(offset) < abs(closest!.offset) { closest = (slot, offset) }
    }
    guard let closest else { return }
    var target = closest.offset > 0 ? closest.slot : closest.slot + 1
    if target > index { target -= 1 }
    target = min(current.bounds.upperBound, max(current.bounds.lowerBound, target))
    guard target != index, time - current.lastHop >= Self.reorderHopInterval else { return }
    let before = screenPositions()
    let moved = motions.remove(at: index)
    motions.insert(moved, at: target)
    rebuild()
    animateMoves(from: before, motion: .system, excluding: current.id)
    reorder?.lastHop = time
    reorderHops &+= 1
  }

  // MARK: Moves

  private func screenPositions() -> [ID: CGFloat] {
    var positions: [ID: CGFloat] = [:]
    for placement in layout.rows where !placement.isExiting {
      positions[placement.row.id] = placement.frame.minY - layout.originY
    }
    return positions
  }

  /// Start each surviving row from its previous screen position.
  private mutating func animateMoves(from before: [ID: CGFloat], motion: ChatListMotion, excluding: ID?) {
    var changed = false
    for index in motions.indices where motions[index].id != excluding && !motions[index].exiting {
      let id = motions[index].id
      guard let old = before[id], let placement = layout.placement(for: id) else { continue }
      let displacement = old - (placement.flowFrame.minY - layout.originY)
      guard abs(displacement - motions[index].offset.value) > 0.01 else { continue }
      motions[index].offset.value = displacement
      motions[index].offset.set(0, motion: motion)
      changed = true
    }
    if changed { rebuild() }
  }

  private mutating func retainPresentedAnchorBeforeRetargeting() {
    guard case var .reading(anchor) = intent,
          let row = layout.placement(for: anchor.id), anchor.localY > row.flowFrame.height,
          let motion = motions.first(where: { $0.id == anchor.id }),
          motion.height.target < anchor.localY || motion.height.velocity < 0 else { return }
    // Shrinking content has removed the saved coordinate. A replacement must
    // start from the coordinate currently presented, rather than recovering an
    // obsolete offset as the row grows again. A newly inserted/growing row can
    // still be on its way to an explicitly requested coordinate; preserve it.
    anchor.localY = row.flowFrame.height
    intent = .reading(anchor)
  }

  /// A keyboard/composer transition owns the usable bottom edge. Capture its
  /// actual visible row before changing either data or the inset target, so a
  /// simultaneous edit above that point cannot push it under the occlusion.
  private mutating func retainInsetAnchor(for next: TimelineViewport) {
    guard case .reading = intent, navigation == nil, entry == nil, nativeOverscroll == 0, reorder == nil else { return }
    guard next.bottomInset != viewport.bottomInset || next.topInset != viewport.topInset else { return }
    let edge = anchorEdge(for: next)
    if let anchor = layout.anchor(edge: edge) { intent = .reading(anchor) }
  }

  private static func phase(of motion: Motion) -> ChatListRowPhase {
    if motion.exiting {
      let progress = motion.exitHeight > 0
        ? 1 - max(0, motion.height.value) / motion.exitHeight
        : 1 - motion.opacity.value
      return .exiting(progress: min(1, max(0, progress)), removal: motion.removal)
    }
    guard let insertion = motion.entering else { return .present }
    let progress: CGFloat
    switch insertion {
      case .grow, .reveal:
        progress = motion.height.target > 0 ? max(0, motion.height.value) / motion.height.target : motion.opacity.value
      case .fade:
        progress = motion.opacity.value
      case .none:
        progress = 1
    }
    return .entering(progress: min(1, max(0, progress)), insertion: insertion)
  }

  private mutating func rebuild() {
    var currentViewport = viewport
    currentViewport.topInset = top.value
    currentViewport.bottomInset = bottom.value
    let bodyHeight = motions.reduce(CGFloat.zero) { $0 + max(0, $1.height.value) }
    let leading = max(0, currentViewport.readingHeight - bodyHeight)
    var y = currentViewport.topInset + leading
    var reach: CGFloat = 0
    var placements = motions.map { motion -> TimelineLayout<ID>.Placement in
      let height = max(0, motion.height.value)
      defer { y += height }
      let flow = CGRect(x: 0, y: y, width: viewport.width, height: height)
      let offset = motion.offset.value
      let displacement = offset + (entry?.offset.value ?? 0)
      if displacement != 0 { reach = max(reach, abs(displacement)) }
      return .init(
        row: .init(id: motion.id, height: height, elements: motion.presentedElements, canAnchor: motion.canAnchor),
        frame: displacement == 0 ? flow : flow.offsetBy(dx: 0, dy: displacement),
        opacity: min(1, max(0, motion.opacity.value)), isExiting: motion.exiting,
        phase: Self.phase(of: motion), flowFrame: flow
      )
    }
    let extent = max(viewport.height, y + currentViewport.bottomInset)
    let maximumOrigin = max(0, extent - viewport.height)
    let desired: CGFloat
    if let reorder {
      desired = reorder.origin
    } else {
      switch intent {
        case .latest:
          desired = maximumOrigin
        case var .reading(anchor):
          if let row = placements.first(where: { $0.row.id == anchor.id }) {
            // A collapse/edit can remove the point inside a surviving row. Keep
            // the reader at its current end instead of skipping later messages.
            // Negative offsets deliberately preserve a gap before the next row.
            let localY = min(anchor.localY, row.flowFrame.height)
            if localY != anchor.localY,
               motions.first(where: { $0.id == anchor.id })?.height.isSettled == true
            {
              anchor.localY = localY
              intent = .reading(anchor)
            }
            desired = row.flowFrame.minY + localY - anchor.viewportPosition(in: currentViewport)
          } else {
            desired = layout.originY
          }
      }
    }
    let clamped = min(maximumOrigin, max(0, desired))
    var origin = clamped
    if var scroll = navigation {
      scroll.target = clamped
      if scroll.isSettled {
        navigation = nil
        navigationCompletions &+= 1
      } else {
        navigation = scroll
        origin = min(maximumOrigin, max(0, scroll.value))
      }
    }
    // A native bounce is displacement from a legal boundary, not a saved
    // reading coordinate. Keep that displacement as the boundary moves.
    let presentedOrigin = nativeOverscroll == 0 ? origin
      : (nativeOverscroll < 0 ? 0 : maximumOrigin) + nativeOverscroll
    if let reorder, let index = placements.firstIndex(where: { $0.row.id == reorder.id }) {
      let floating = presentedOrigin + reorder.touchY - reorder.grab
      reach = max(reach, abs(floating - placements[index].flowFrame.minY))
      placements[index].frame.origin.y = floating
      placements[index].isReordering = true
    }
    var departingIDs = Set<ID>()
    if let entry {
      let travelled = entry.offset.value - entry.start
      for index in placements.indices {
        if let departing = motions[index].departing {
          placements[index].frame = CGRect(
            x: 0, y: presentedOrigin + departing.screenY + travelled, width: viewport.width, height: departing.height
          )
          placements[index].opacity = 1
          departingIDs.insert(placements[index].row.id)
        } else if let limit = entry.hidesBelow, placements[index].flowFrame.minY >= limit {
          placements[index].isSuppressed = true
          placements[index].opacity = 0
        } else if let limit = entry.hidesAbove, placements[index].flowFrame.maxY <= limit {
          placements[index].isSuppressed = true
          placements[index].opacity = 0
        }
      }
    }
    layout = TimelineLayout(
      rows: placements,
      viewport: currentViewport,
      contentHeight: extent,
      originY: presentedOrigin,
      reorderingID: reorder?.id,
      departingIDs: departingIDs,
      offsetReach: reach
    )
  }
}
