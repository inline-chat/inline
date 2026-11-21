#if canImport(AppKit)
import AppKit
import ChatListCore
import QuartzCore

@MainActor
private final class ChatListNativeScrollView: NSScrollView {
  var onWheel: (() -> Void)?

  override func scrollWheel(with event: NSEvent) {
    onWheel?()
    super.scrollWheel(with: event)
  }
}

@MainActor
private final class ChatListScrollObserver: NSObject {
  var onBoundsChanged: (() -> Void)?
  var onLiveScrollStarted: (() -> Void)?
  var onLiveScrollEnded: (() -> Void)?

  @objc func boundsChanged(_ notification: Notification) { onBoundsChanged?() }
  @objc func liveScrollStarted(_ notification: Notification) { onLiveScrollStarted?() }
  @objc func liveScrollEnded(_ notification: Notification) { onLiveScrollEnded?() }
}

/// A non-generic Objective-C target for gesture recognizers.
@MainActor
private final class ChatListGestureTarget: NSObject {
  var handler: ((NSGestureRecognizer) -> Void)?
  @objc func handle(_ recognizer: NSGestureRecognizer) { handler?(recognizer) }
}

@MainActor
private final class ChatListPassthroughOverlayView: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
private final class ChatListRowSlot: NSView {
  private(set) var cell: NSView

  override var isFlipped: Bool { true }

  init(cell: NSView) {
    self.cell = cell
    super.init(frame: .zero)
    autoresizesSubviews = false
    wantsLayer = true
    layer?.masksToBounds = true
    setAccessibilityElement(false)
    setCell(cell)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setCell(_ next: NSView) {
    if cell !== next {
      cell.removeFromSuperview()
      cell = next
    }
    if next.superview !== self {
      next.translatesAutoresizingMaskIntoConstraints = true
      next.autoresizingMask = []
      addSubview(next)
    }
  }
}

/// An upright, virtual AppKit host for exact prepared row geometry. The app
/// supplies arbitrary native cells and owns all content measurement and actions.
@MainActor
public final class ChatListView<ID: Hashable & Sendable, Content>: NSView {
  private struct Binding {
    let revision: UInt64
    let context: ChatListLayoutContext
    let reuseIdentifier: String
  }

  private struct SemanticAnchor {
    var id: ID
    var cellAnchor: ChatListCellAnchor
    var viewportY: CGFloat
    var edge: TimelineAnchorEdge
    var location: ChatListAnchorLocation?
    var needsResolution: Bool
    var expectedIntent: TimelineIntent<ID>?
  }

  public let session: ChatListSession<ID, Content>
  public let scrollView: NSScrollView = ChatListNativeScrollView(frame: .zero)
  /// Sticky app content may be installed here; empty space passes native input.
  public let overlayView: NSView = ChatListPassthroughOverlayView(frame: .zero)
  public var configuration: ChatListConfiguration {
    didSet {
      guard session.isCurrentHost(self) else { return }
      session.historyTriggerDistance = configuration.historyTriggerDistance
      document.overscan = configuration.overscan
      document.maximumReusableViewsPerKind = configuration.maximumReusableCellsPerKind
      document.trimReusePool()
      updateClock()
      installPresentation()
    }
  }

  /// The factory may return the supplied reusable view or a new native view.
  public var makeCell: (ChatListItem<ID, Content>, NSView?) -> NSView
  /// Called for a new resident, changed revision, or changed prepared context.
  public var bindCell: ((NSView, ChatListItem<ID, Content>, ChatListLayoutContext) -> Void)?
  /// Called each presented frame after the row slot has its animated frame.
  public var presentCell: ((NSView, TimelineLayout<ID>.Placement) -> Void)?
  public var presentOverlays: ((NSView, TimelineLayout<ID>) -> Void)?
  public var recycleCell: ((NSView) -> Void)?
  public var captureCellAnchor: ((NSView, ChatListItem<ID, Content>, CGRect) -> ChatListCellAnchor?)?
  public var resolveCellAnchor: ((NSView, ChatListItem<ID, Content>, ChatListCellAnchor) -> ChatListAnchorLocation?)?
  /// A resident cell's share of the usable viewport changed.
  public var updateCellVisibility: ((NSView, ChatListRowVisibility) -> Void)?
  /// An inserted row became resident.
  public var didInsertCell: ((NSView, ChatListItem<ID, Content>, ChatListInsertion) -> Void)?
  /// A resident row is about to animate out; `frame` is in this view's coordinates.
  public var willRemoveCell: ((NSView, ChatListItem<ID, Content>, ChatListRemovalEvent<ID>) -> Void)?
  /// A row was lifted or dropped by the reorder gesture.
  public var cellReorderStateChanged: ((NSView, Bool) -> Void)?

  /// Telegram's lifted row shadow: blur 18, 35% black.
  public var reorderedRowHasShadow = true
  /// Fill the area revealed when bouncing past the first or last row.
  public var topOverscrollColor: NSColor? { didSet { updateOverscrollViews() } }
  public var bottomOverscrollColor: NSColor? { didSet { updateOverscrollViews() } }

  /// Press and hold, then drag, to move rows the session's `canReorder` accepts.
  public var isReorderingEnabled = false {
    didSet { reorderGesture.isEnabled = isReorderingEnabled }
  }

  public var materializedCells: [ID: NSView] {
    document.materialized.compactMapValues { ($0 as? ChatListRowSlot)?.cell }
  }

  private let document = TimelineDocumentView<ID>(frame: .zero)
  private let displayClock = TimelineDisplayClock()
  private let scrollObserver = ChatListScrollObserver()
  private var bindings: [ID: Binding] = [:]
  private var idsBySlot: [ObjectIdentifier: ID] = [:]
  private var explicitPins: Set<ID> = []
  private var semanticAnchor: SemanticAnchor?
  private var isInstalling = false
  private var installRequested = false
  private var isLayingOut = false
  private var isAssigningOrigin = false
  private var isNativeScroll = false
  private var isLiveScroll = false
  private var lastObservedOrigin: CGFloat = 0
  private var nativeScrollEnd: Task<Void, Never>?
  private var lastClipSize: CGSize = .zero
  private var lastAttachedScale: CGFloat
  private var didPresentScheduled = false
  private var visibilities: [ID: ChatListRowVisibility] = [:]
  private var hiddenIDs: Set<ID> = []
  private var liftedID: ID?
  private let reorderGesture = NSPressGestureRecognizer()
  private let reorderTarget = ChatListGestureTarget()
  private let topOverscrollView = NSView(frame: .zero)
  private let bottomOverscrollView = NSView(frame: .zero)
  var automaticFrameObserver: (() -> Void)?
  var isAutomaticClockRunning: Bool { displayClock.isRunning }

  public init(
    session: ChatListSession<ID, Content>, configuration: ChatListConfiguration = .init(),
    makeCell: @escaping (ChatListItem<ID, Content>, NSView?) -> NSView
  ) {
    self.session = session
    self.configuration = configuration
    self.makeCell = makeCell
    self.lastAttachedScale = session.layoutContext.displayScale
    super.init(frame: .zero)

    wantsLayer = true
    scrollView.translatesAutoresizingMaskIntoConstraints = true
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.hasHorizontalScroller = false
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = .init()
    scrollView.documentView = document
    scrollView.contentView.postsBoundsChangedNotifications = true
    overlayView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(scrollView)
    addSubview(overlayView)

    document.overscan = configuration.overscan
    document.maximumReusableViewsPerKind = configuration.maximumReusableCellsPerKind
    document.reuseIdentifier = { [weak self] id in self?.session.item(for: id)?.reuseIdentifier ?? "cell" }
    document.makeView = { [weak self] id, reused in self?.makeSlot(for: id, reused: reused) }
    document.presentView = { [weak self] id, view, placement in
      self?.present(id: id, view: view, placement: placement)
    }
    document.recycleView = { [weak self] view in self?.recycle(view) }

    scrollObserver.onBoundsChanged = { [weak self] in self?.clipBoundsChanged() }
    scrollObserver.onLiveScrollStarted = { [weak self] in self?.liveScrollStarted() }
    scrollObserver.onLiveScrollEnded = { [weak self] in self?.liveScrollEnded() }
    NotificationCenter.default.addObserver(
      scrollObserver, selector: #selector(ChatListScrollObserver.boundsChanged(_:)),
      name: NSView.boundsDidChangeNotification, object: scrollView.contentView
    )
    NotificationCenter.default.addObserver(
      scrollObserver, selector: #selector(ChatListScrollObserver.liveScrollStarted(_:)),
      name: NSScrollView.willStartLiveScrollNotification, object: scrollView
    )
    NotificationCenter.default.addObserver(
      scrollObserver, selector: #selector(ChatListScrollObserver.liveScrollEnded(_:)),
      name: NSScrollView.didEndLiveScrollNotification, object: scrollView
    )
    (scrollView as? ChatListNativeScrollView)?.onWheel = { [weak self] in
      guard let self, self.isNativeScroll else { return }
      self.scheduleNativeScrollEnd()
    }

    reorderTarget.handler = { [weak self] recognizer in self?.handleReorder(recognizer) }
    reorderGesture.target = reorderTarget
    reorderGesture.action = #selector(ChatListGestureTarget.handle(_:))
    reorderGesture.minimumPressDuration = 0.25
    reorderGesture.isEnabled = false
    document.addGestureRecognizer(reorderGesture)

    session.attachHost(
      owner: self,
      willApply: { [weak self] intent in self?.captureBeforeApply(intent: intent) },
      presentationChanged: { [weak self] in self?.installPresentation() },
      willRemove: { [weak self] events in self?.willRemove(events) }
    )
    if session.isCurrentHost(self) {
      session.historyTriggerDistance = configuration.historyTriggerDistance
    }
    displayClock.onFrame = { [weak self] time in
      guard let self else { return }
      automaticFrameObserver?()
      guard session.isCurrentHost(self), session.isActive else { updateClock(); return }
      session.advance(to: time)
      updateClock()
    }
    installPresentation()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  isolated deinit {
    nativeScrollEnd?.cancel()
    displayClock.stop()
    NotificationCenter.default.removeObserver(scrollObserver)
    session.detachHost(owner: self)
  }

  public override func layout() {
    isLayingOut = true
    defer {
      lastObservedOrigin = scrollView.contentView.bounds.minY
      isLayingOut = false
    }
    super.layout()
    scrollView.frame = bounds
    overlayView.frame = bounds
    updateViewportIfNeeded()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil, liftedID != nil { finishReorder(cancelled: true) }
    if window == nil {
      nativeScrollEnd?.cancel()
      nativeScrollEnd = nil
      isNativeScroll = false
      isLiveScroll = false
    }
    guard session.isCurrentHost(self) else { updateClock(); return }
    session.setActive(window != nil, at: CACurrentMediaTime())
    updateViewportIfNeeded()
    updateClock()
    if window != nil { installPresentation() }
  }

  /// Hold a row resident during a menu, text selection, or another interaction.
  public func pinCell(for id: ID) {
    explicitPins.insert(id)
    document.pin(id)
    installPresentation()
  }

  public func unpinCell(for id: ID) {
    explicitPins.remove(id)
    if semanticAnchor?.id != id { document.unpin(id) }
    installPresentation()
  }

  public func cell(for id: ID) -> NSView? { (document.materialized[id] as? ChatListRowSlot)?.cell }

  /// Hide a row's cell while another view stands in for it.
  public func setCellHidden(_ hidden: Bool, for id: ID) {
    if hidden { hiddenIDs.insert(id) } else { hiddenIDs.remove(id) }
    document.materialized[id]?.isHidden = hidden
  }

  /// A row's presented frame in this view's coordinates.
  public func frame(for id: ID) -> CGRect? { session.timeline.layout.viewportFrame(for: id) }

  /// Advance the deterministic session clock without an automatic display link.
  public func advance(to time: Double) {
    guard session.isCurrentHost(self) else { return }
    session.advance(to: time)
  }

  private func updateViewportIfNeeded() {
    guard session.isCurrentHost(self) else { return }
    let size = scrollView.contentView.bounds.size
    if let window { lastAttachedScale = window.backingScaleFactor }
    let scale = lastAttachedScale
    guard size != lastClipSize || session.layoutContext.displayScale != scale else { return }
    lastClipSize = size
    let old = session.timeline.targetViewport
    session.updateViewport(
      TimelineViewport(width: size.width, height: size.height,
                       topInset: old.topInset, bottomInset: old.bottomInset),
      displayScale: scale,
      environmentRevision: session.layoutContext.environmentRevision,
      animation: .none,
      at: CACurrentMediaTime()
    )
    installPresentation()
  }

  private func makeSlot(for id: ID, reused: NSView?) -> NSView? {
    guard let item = session.item(for: id) else { return nil }
    let reusableSlot = reused as? ChatListRowSlot
    let cell = makeCell(item, reusableSlot?.cell)
    let slot: ChatListRowSlot
    if let reusableSlot {
      reusableSlot.setCell(cell)
      slot = reusableSlot
    } else {
      slot = ChatListRowSlot(cell: cell)
    }
    idsBySlot[ObjectIdentifier(slot)] = id
    return slot
  }

  private func present(id: ID, view: NSView, placement: TimelineLayout<ID>.Placement) {
    guard let slot = view as? ChatListRowSlot, let item = session.item(for: id) else { return }
    let context = session.snapshot?.context ?? session.layoutContext
    let prior = bindings[id]
    slot.isHidden = hiddenIDs.contains(id)
    if placement.isReordering, document.subviews.last !== slot {
      document.addSubview(slot, positioned: .above, relativeTo: nil)
    }
    if !placement.isExiting,
       prior == nil || prior?.revision != item.revision || prior?.context != context
         || prior?.reuseIdentifier != item.reuseIdentifier {
      let contentFrame = CGRect(x: 0, y: 0, width: context.width, height: item.height)
      if slot.cell.frame != contentFrame { slot.cell.frame = contentFrame }
      bindCell?(slot.cell, item, context)
      bindings[id] = Binding(
        revision: item.revision, context: context, reuseIdentifier: item.reuseIdentifier
      )
      if prior == nil, case let .entering(_, insertion) = placement.phase {
        didInsertCell?(slot.cell, item, insertion)
      }
    }
    presentCell?(slot.cell, placement)
    if let updateCellVisibility {
      let visibility = session.timeline.layout.visibility(for: id)
      if visibilities[id] != visibility {
        visibilities[id] = visibility
        updateCellVisibility(slot.cell, visibility)
      }
    }
  }

  private func recycle(_ view: NSView) {
    guard let slot = view as? ChatListRowSlot else { return }
    if let id = idsBySlot.removeValue(forKey: ObjectIdentifier(slot)) {
      bindings.removeValue(forKey: id)
      if let visibility = visibilities.removeValue(forKey: id), visibility != .hidden {
        updateCellVisibility?(slot.cell, .hidden)
      }
    }
    slot.isHidden = false
    recycleCell?(slot.cell)
  }

  private func willRemove(_ events: [ChatListRemovalEvent<ID>]) {
    guard let willRemoveCell else { return }
    for event in events {
      guard let cell = cell(for: event.id), let item = session.item(for: event.id) else { continue }
      willRemoveCell(cell, item, event)
    }
  }

  private func handleReorder(_ recognizer: NSGestureRecognizer) {
    guard session.isCurrentHost(self) else { return }
    let point = recognizer.location(in: self)
    // AppKit hosts are unflipped; viewport coordinates run top-down.
    let touchY = isFlipped ? point.y : bounds.height - point.y
    let time = CACurrentMediaTime()
    switch recognizer.state {
      case .began:
        let documentPoint = recognizer.location(in: document)
        guard let id = document.row(at: documentPoint),
              session.beginReorder(id: id, touchY: touchY, at: time) else {
          recognizer.isEnabled = false
          recognizer.isEnabled = isReorderingEnabled
          return
        }
        liftedID = id
        document.pin(id)
        if let cell = cell(for: id) { cellReorderStateChanged?(cell, true) }
        setLifted(true, id: id)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        updateClock()
      case .changed:
        session.updateReorder(touchY: touchY, at: time)
        updateClock()
      case .ended:
        finishReorder(cancelled: false)
      default:
        finishReorder(cancelled: true)
    }
  }

  private func finishReorder(cancelled: Bool) {
    guard let id = liftedID else { return }
    liftedID = nil
    if cancelled { session.cancelReorder(at: CACurrentMediaTime()) }
    else { session.endReorder(at: CACurrentMediaTime()) }
    if !explicitPins.contains(id), semanticAnchor?.id != id { document.unpin(id) }
    if let cell = cell(for: id) { cellReorderStateChanged?(cell, false) }
    setLifted(false, id: id)
    updateClock()
  }

  private func setLifted(_ lifted: Bool, id: ID) {
    guard reorderedRowHasShadow, let layer = document.materialized[id]?.layer else { return }
    layer.masksToBounds = !lifted
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOffset = .zero
    layer.shadowRadius = 9
    layer.shadowOpacity = lifted ? 0.35 : 0
  }

  private func updateOverscrollViews() {
    for (view, color) in [(topOverscrollView, topOverscrollColor), (bottomOverscrollView, bottomOverscrollColor)] {
      view.wantsLayer = true
      view.layer?.backgroundColor = color?.cgColor
      view.isHidden = color == nil
      if color != nil, view.superview !== document {
        document.addSubview(view, positioned: .below, relativeTo: nil)
      }
    }
    let layout = session.timeline.layout
    layoutOverscrollViews(contentHeight: layout.contentHeight, width: layout.viewport.width)
  }

  private func layoutOverscrollViews(contentHeight: CGFloat, width: CGFloat) {
    let height = max(bounds.height, 1)
    if topOverscrollColor != nil {
      topOverscrollView.frame = CGRect(x: 0, y: -height, width: width, height: height)
    }
    if bottomOverscrollColor != nil {
      bottomOverscrollView.frame = CGRect(x: 0, y: contentHeight, width: width, height: height)
    }
  }

  private func captureBeforeApply(intent: TimelineIntent<ID>?) {
    guard session.isCurrentHost(self) else { return }
    clearSemanticAnchor()
    guard intent == nil, case .reading = session.timeline.intent,
          !session.isUserScrolling, !isNativeScroll, let captureCellAnchor else {
      return
    }
    let layout = session.timeline.layout
    let reading = layout.readingRect
    let edge = session.anchorEdge
    let visible = layout.visibleRows(in: reading)
    let ordered = edge == .top ? Array(visible) : Array(visible.reversed())
    for index in ordered {
      let placement = layout.rows[index]
      guard !placement.isExiting, placement.row.canAnchor,
            let cell = cell(for: placement.row.id),
            let item = session.item(for: placement.row.id) else { continue }
      let localVisible = reading.intersection(placement.frame).offsetBy(
        dx: -placement.frame.minX, dy: -placement.frame.minY
      )
      guard !localVisible.isNull,
            let address = captureCellAnchor(cell, item, localVisible),
            address.localY.isFinite else { continue }
      semanticAnchor = .init(
        id: placement.row.id, cellAnchor: address,
        viewportY: edge == .top
          ? placement.frame.minY + address.localY - reading.minY
          : layout.originY + layout.viewport.height - layout.viewport.bottomInset - placement.frame.minY - address.localY,
        edge: edge,
        location: nil, needsResolution: true, expectedIntent: nil
      )
      document.pin(placement.row.id)
      break
    }
  }

  private func refineSemanticAnchor(in layout: TimelineLayout<ID>) {
    guard session.isCurrentHost(self) else { return }
    guard var anchor = semanticAnchor else { return }
    guard !session.isUserScrolling, !isNativeScroll, !session.timeline.isNavigating,
          let placement = layout.placement(for: anchor.id), !placement.isExiting,
          let cell = cell(for: anchor.id) else {
      clearSemanticAnchor()
      return
    }
    if let expectedIntent = anchor.expectedIntent, expectedIntent != session.timeline.intent {
      clearSemanticAnchor()
      return
    }
    if anchor.needsResolution {
      guard let item = session.item(for: anchor.id),
            let location = resolveCellAnchor?(cell, item, anchor.cellAnchor),
            location.localY(in: placement.row.elements) != nil else {
        clearSemanticAnchor()
        return
      }
      anchor.location = location
      anchor.needsResolution = false
    }
    guard let location = anchor.location,
          session.isCurrentHost(self),
          session.refineAnchor(row: anchor.id, location: location, viewportY: anchor.viewportY, edge: anchor.edge) else {
      clearSemanticAnchor()
      return
    }
    anchor.expectedIntent = session.timeline.intent
    semanticAnchor = anchor
    let corrected = session.timeline.layout
    if abs(scrollView.contentView.bounds.minY - corrected.originY) > 0.01 {
      assignOrigin(corrected.originY)
      document.refineScrollOrigin(
        to: corrected.originY,
        visibleRect: CGRect(x: 0, y: scrollView.contentView.bounds.minY,
                            width: corrected.viewport.width, height: scrollView.contentView.bounds.height)
      )
    }
  }

  private func clearSemanticAnchor() {
    if let semanticAnchor, !explicitPins.contains(semanticAnchor.id) {
      document.unpin(semanticAnchor.id)
    }
    semanticAnchor = nil
  }

  private func installPresentation() {
    guard session.isCurrentHost(self) || session.isDisposed else { updateClock(); return }
    guard !session.isDisposed else {
      document.clear()
      bindings.removeAll()
      idsBySlot.removeAll()
      displayClock.stop()
      return
    }
    if isInstalling { installRequested = true; return }
    isInstalling = true
    defer {
      isInstalling = false
      if installRequested {
        installRequested = false
        installPresentation()
      }
    }
    let layout = session.timeline.layout
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Occlusions shorten the indicator track, without giving AppKit a second
    // owner for content geometry or scroll compensation.
    if scrollView.scrollerInsets.top != layout.viewport.topInset
      || scrollView.scrollerInsets.bottom != layout.viewport.bottomInset {
      scrollView.scrollerInsets = NSEdgeInsets(
        top: layout.viewport.topInset, left: 0,
        bottom: layout.viewport.bottomInset, right: 0
      )
    }
    let size = CGSize(width: layout.viewport.width, height: layout.contentHeight)
    if document.frame.size != size { document.setFrameSize(size) }
    // The session preserves native bounce displacement while live occlusions
    // move its legal boundary. Apply only that geometry compensation.
    if abs(scrollView.contentView.bounds.minY - layout.originY) > 0.01 {
      assignOrigin(layout.originY)
    }
    let visibleRect = CGRect(
      x: 0, y: scrollView.contentView.bounds.minY,
      width: layout.viewport.width, height: scrollView.contentView.bounds.height
    )
    layoutOverscrollViews(contentHeight: layout.contentHeight, width: layout.viewport.width)
    document.install(layout, visibleRect: visibleRect)
    refineSemanticAnchor(in: layout)
    presentOverlays?(overlayView, session.timeline.layout)
    lastObservedOrigin = scrollView.contentView.bounds.minY
    CATransaction.commit()
    updateClock()
    scheduleDidPresent()
  }

  private func assignOrigin(_ origin: CGFloat) {
    isAssigningOrigin = true
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    lastObservedOrigin = scrollView.contentView.bounds.minY
    isAssigningOrigin = false
  }

  private func beginNativeScroll() {
    guard window != nil, !isAssigningOrigin, !isInstalling, !isLayingOut,
          session.isCurrentHost(self), session.isActive else { return }
    if !isNativeScroll {
      clearSemanticAnchor()
      isNativeScroll = true
      session.beginUserScroll(at: scrollView.contentView.bounds.minY)
    }
    scheduleNativeScrollEnd()
  }

  private func liveScrollStarted() {
    guard session.isCurrentHost(self), session.isActive, window != nil else { return }
    isLiveScroll = true
    nativeScrollEnd?.cancel()
    nativeScrollEnd = nil
    // A phase-began notification can precede any clip movement. Keep the
    // restored anchor (including Latest) until bounds actually change.
  }

  private func liveScrollEnded() {
    isLiveScroll = false
    finishNativeScroll()
  }

  private func clipBoundsChanged() {
    guard window != nil, !isAssigningOrigin, !isInstalling, !isLayingOut,
          session.isCurrentHost(self), session.isActive else { return }
    let origin = scrollView.contentView.bounds.minY
    guard abs(origin - lastObservedOrigin) > 0.01 else { return }
    lastObservedOrigin = origin
    beginNativeScroll()
    session.userScrolled(to: origin)
    installPresentation()
  }

  private func scheduleNativeScrollEnd() {
    guard session.isCurrentHost(self), session.isActive, !isLiveScroll else { return }
    nativeScrollEnd?.cancel()
    nativeScrollEnd = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      self?.finishNativeScroll()
    }
  }

  private func finishNativeScroll() {
    guard session.isCurrentHost(self) else { return }
    guard !isLiveScroll else { return }
    guard isNativeScroll else { return }
    let origin = scrollView.contentView.bounds.minY
    if origin < -0.01 || origin > session.timeline.layout.maximumOrigin + 0.01 {
      scheduleNativeScrollEnd()
      return
    }
    nativeScrollEnd?.cancel()
    nativeScrollEnd = nil
    isNativeScroll = false
    session.endUserScroll(at: origin)
    installPresentation()
  }

  private func updateClock() {
    if !session.isCurrentHost(self) || !session.isActive {
      nativeScrollEnd?.cancel()
      nativeScrollEnd = nil
      isNativeScroll = false
      isLiveScroll = false
    }
    if configuration.usesAutomaticDisplayClock, let window,
       session.isCurrentHost(self), session.isActive, session.needsDisplayFrames {
      displayClock.start(in: window)
    } else {
      displayClock.stop()
    }
  }

  private func scheduleDidPresent() {
    guard !didPresentScheduled else { return }
    didPresentScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      didPresentScheduled = false
      guard session.isCurrentHost(self) else { return }
      session.historyTriggerDistance = configuration.historyTriggerDistance
      session.didPresent()
    }
  }
}
#endif
