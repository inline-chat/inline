#if canImport(UIKit)
import ChatListCore
import QuartzCore
import UIKit

/// An upright, virtual UIKit host for a prepared chat timeline. Cell factories
/// install native content; the session is the only owner of list geometry.
@MainActor
public final class ChatListView<ID: Hashable & Sendable, Content>: UIView, UIScrollViewDelegate {
  private final class PassthroughOverlayView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      let hit = super.hitTest(point, with: event)
      return hit === self ? nil : hit
    }
  }

  private final class RowSlot: UIView {
    let cell: UIView

    init(cell: UIView) {
      self.cell = cell
      super.init(frame: .zero)
      autoresizesSubviews = false
      clipsToBounds = true
      isAccessibilityElement = false
      cell.translatesAutoresizingMaskIntoConstraints = true
      cell.autoresizingMask = []
      addSubview(cell)
      accessibilityElements = [cell]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  }

  /// A non-generic Objective-C target for gesture recognizers.
  private final class GestureTarget: NSObject {
    var handler: ((UIGestureRecognizer) -> Void)?
    @objc func handle(_ recognizer: UIGestureRecognizer) { handler?(recognizer) }
  }

  private struct Resident {
    var slot: RowSlot
    var revision: UInt64
    var context: ChatListLayoutContext
    var reuseIdentifier: String
    var visibility: ChatListRowVisibility = .hidden
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

  /// An animated keyboard change, in this view's coordinates. Each frame the
  /// list takes the keyboard's edge for the frame being rendered, so it stays
  /// pinned to the edge and holds still until the keyboard really starts.
  private struct KeyboardTransition {
    var from: CGFloat
    var to: CGFloat
    var end: Double
    var followsSystemSpring: Bool
    var lastSample: (time: Double, edge: CGFloat)?
  }

  public let session: ChatListSession<ID, Content>
  public private(set) var scrollView = UIScrollView(frame: .zero)
  /// Sticky app content can be installed here without blocking empty space.
  public let overlayView: UIView = PassthroughOverlayView(frame: .zero)
  public var configuration: ChatListConfiguration {
    didSet {
      guard session.isCurrentHost(self) else { return }
      session.historyTriggerDistance = configuration.historyTriggerDistance
      trimReusePool()
      updateClock()
      installPresentation()
    }
  }

  /// The factory may return the supplied reusable view or a new native view.
  public var makeCell: (ChatListItem<ID, Content>, UIView?) -> UIView
  /// Called for a new resident, a changed item revision, or changed layout context.
  public var bindCell: ((UIView, ChatListItem<ID, Content>, ChatListLayoutContext) -> Void)?
  /// Called on every presented frame, after the row slot has its exact frame.
  /// `placement.phase` carries insertion/removal progress on the list clock.
  public var presentCell: ((UIView, TimelineLayout<ID>.Placement) -> Void)?
  /// Position overlays against the same row presentation and clip origin.
  public var presentOverlays: ((UIView, TimelineLayout<ID>) -> Void)?
  public var recycleCell: ((UIView) -> Void)?
  public var captureCellAnchor: ((UIView, ChatListItem<ID, Content>, CGRect) -> ChatListCellAnchor?)?
  public var resolveCellAnchor: ((UIView, ChatListItem<ID, Content>, ChatListCellAnchor) -> ChatListAnchorLocation?)?
  /// A resident cell's share of the usable viewport changed (Telegram's
  /// item visibility): autoplay, read marks, pausing animations.
  public var updateCellVisibility: ((UIView, ChatListRowVisibility) -> Void)?
  /// An inserted row became resident (Telegram's `animateInsertion`).
  public var didInsertCell: ((UIView, ChatListItem<ID, Content>, ChatListInsertion) -> Void)?
  /// A resident row is about to animate out; `frame` is in this view's
  /// coordinates (Telegram's `animateRemoved`, dust effects).
  public var willRemoveCell: ((UIView, ChatListItem<ID, Content>, ChatListRemovalEvent<ID>) -> Void)?
  /// A row was lifted or dropped by the reorder gesture (shadow, scale).
  public var cellReorderStateChanged: ((UIView, Bool) -> Void)?
  /// Fill the area revealed when bouncing past the first or last row.
  public var topOverscrollColor: UIColor? { didSet { updateOverscrollViews() } }
  public var bottomOverscrollColor: UIColor? { didSet { updateOverscrollViews() } }

  /// Telegram's lifted row shadow: blur 18, 35% black, fading in over 0.25 s.
  public var reorderedRowHasShadow = true
  /// Long-press to lift and drag rows the session's `canReorder` accepts.
  public var isReorderingEnabled = false {
    didSet { reorderGesture.isEnabled = isReorderingEnabled }
  }

  /// Track the system keyboard: the bottom inset becomes the keyboard's
  /// occlusion plus `bottomAccessoryHeight`, moving on the keyboard's curve,
  /// and interactive dismissal follows the drag in the same frame.
  public var tracksKeyboard = false {
    didSet { configureKeyboardTracking() }
  }

  public private(set) var keyboardOcclusion: CGFloat = 0
  public private(set) var bottomAccessoryHeight: CGFloat = 0
  public private(set) var topInset: CGFloat = 0

  public var materializedCells: [ID: UIView] {
    residents.mapValues(\.slot.cell)
  }

  private let canvas = UIView(frame: .zero)
  private let displayClock = DisplayClock()
  private let topOverscrollView = UIView(frame: .zero)
  private let bottomOverscrollView = UIView(frame: .zero)
  private let keyboardProbe = UIView(frame: .zero)
  private let reorderGesture = UILongPressGestureRecognizer()
  private let reorderTarget = GestureTarget()
  private var residents: [ID: Resident] = [:]
  private var reusePool: [String: [UIView]] = [:]
  private var pinnedIDs: Set<ID> = []
  private var hiddenIDs: Set<ID> = []
  private var liftedID: ID?
  private var accessibilityOrder: [ID] = []
  private var accessibilitySlotIDs: [ObjectIdentifier] = []
  private var semanticAnchor: SemanticAnchor?
  private var isInstalling = false
  private var installRequested = false
  private var layoutDepth = 0
  private var isAssigningOffset = false
  private var isNativeScroll = false
  private var lastBoundsSize: CGSize = .zero
  private var lastScreenScale: CGFloat?
  private var didPresentScheduled = false
  private var keyboardObserver: NSObjectProtocol?
  private var keyboardNote: (time: Double, duration: Double, curve: Int)?
  private var keyboardTransition: KeyboardTransition?
  private var lastKeyboardEdge: CGFloat?
  private var keyboardConstraints: [NSLayoutConstraint] = []
  private let liftFeedback = UIImpactFeedbackGenerator(style: .medium)
  private let hopFeedback = UISelectionFeedbackGenerator()
  private var seenReorderHops: UInt64 = 0
  var automaticFrameObserver: (() -> Void)?
  var isAutomaticClockRunning: Bool { displayClock.isRunning }

  public init(
    session: ChatListSession<ID, Content>,
    configuration: ChatListConfiguration = .init(),
    makeCell: @escaping (ChatListItem<ID, Content>, UIView?) -> UIView
  ) {
    self.session = session
    self.configuration = configuration
    self.makeCell = makeCell
    super.init(frame: .zero)
    clipsToBounds = true
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.contentInset = .zero
    scrollView.verticalScrollIndicatorInsets = .zero
    scrollView.alwaysBounceHorizontal = false
    scrollView.alwaysBounceVertical = true
    scrollView.isDirectionalLockEnabled = true
    scrollView.delegate = self
    scrollView.translatesAutoresizingMaskIntoConstraints = true
    topOverscrollView.isHidden = true
    bottomOverscrollView.isHidden = true
    scrollView.addSubview(topOverscrollView)
    scrollView.addSubview(bottomOverscrollView)
    scrollView.addSubview(canvas)
    canvas.isAccessibilityElement = false
    addSubview(scrollView)
    addSubview(overlayView)
    keyboardProbe.isHidden = true
    keyboardProbe.isUserInteractionEnabled = false
    keyboardProbe.translatesAutoresizingMaskIntoConstraints = false

    reorderTarget.handler = { [weak self] recognizer in self?.handleReorder(recognizer) }
    reorderGesture.addTarget(reorderTarget, action: #selector(GestureTarget.handle(_:)))
    reorderGesture.minimumPressDuration = 0.25
    reorderGesture.isEnabled = false
    scrollView.addGestureRecognizer(reorderGesture)

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
      followKeyboard(at: time)
      session.advance(to: time)
      updateClock()
    }
    installPresentation()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  isolated deinit {
    displayClock.stop()
    if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
    session.detachHost(owner: self)
  }

  public override func layoutSubviews() {
    layoutDepth += 1
    defer { layoutDepth -= 1 }
    super.layoutSubviews()
    scrollView.frame = bounds
    overlayView.frame = bounds
    updateViewportIfNeeded()
    if tracksKeyboard { keyboardGuideMoved() }
  }

  private func updateViewportIfNeeded() {
    guard session.isCurrentHost(self) else { return }
    let scale = window?.screen.scale ?? lastScreenScale ?? UIScreen.main.scale
    if window != nil { lastScreenScale = scale }
    guard bounds.size != lastBoundsSize || session.layoutContext.displayScale != scale else { return }
    lastBoundsSize = bounds.size
    let old = session.timeline.targetViewport
    session.updateViewport(
      TimelineViewport(
        width: bounds.width, height: bounds.height,
        topInset: old.topInset, bottomInset: old.bottomInset
      ),
      displayScale: scale,
      environmentRevision: session.layoutContext.environmentRevision,
      animation: .none,
      at: CACurrentMediaTime()
    )
    installPresentation()
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    if tracksKeyboard { configureKeyboardTracking() }
    if window == nil {
      // UIKit may remove a view before sending the drag/deceleration end
      // delegate callbacks. A later attachment starts a fresh native phase.
      if isNativeScroll { semanticAnchor = nil }
      isNativeScroll = false
      if liftedID != nil { finishReorder(cancelled: true) }
    }
    guard session.isCurrentHost(self) else { updateClock(); return }
    session.setActive(window != nil, at: CACurrentMediaTime())
    updateViewportIfNeeded()
    updateClock()
    if window != nil { installPresentation() }
  }

  /// Retain an offscreen resident during a menu, text selection, or other
  /// native interaction. The app must release its explicit pin afterward.
  public func pinCell(for id: ID) {
    pinnedIDs.insert(id)
    installPresentation()
  }

  public func unpinCell(for id: ID) {
    pinnedIDs.remove(id)
    installPresentation()
  }

  /// Hide a row's cell while another view stands in for it, e.g. the bubble
  /// flying from the composer during a send transition.
  public func setCellHidden(_ hidden: Bool, for id: ID) {
    if hidden { hiddenIDs.insert(id) } else { hiddenIDs.remove(id) }
    residents[id]?.slot.isHidden = hidden
  }

  public func cell(for id: ID) -> UIView? { residents[id]?.slot.cell }

  /// A row's presented frame in this view's coordinates.
  public func frame(for id: ID) -> CGRect? { session.timeline.layout.viewportFrame(for: id) }

  /// Set occlusions. With keyboard tracking the bottom inset adds the
  /// keyboard's occlusion to `bottomAccessory`.
  public func setInsets(top: CGFloat, bottomAccessory: CGFloat, animation: ChatListAnimation = .animated) {
    topInset = max(0, top)
    bottomAccessoryHeight = max(0, bottomAccessory)
    submitInsets(animation: animation, at: CACurrentMediaTime(), adjustment: .preserveAnchor)
  }

  /// Advance the deterministic session clock when automatic display timing is disabled.
  public func advance(to time: Double) {
    guard session.isCurrentHost(self) else { return }
    session.advance(to: time)
  }

  // MARK: Native scrolling

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guard session.isCurrentHost(self), session.isActive, !session.isDisposed else { return }
    semanticAnchor = nil
    isNativeScroll = true
    session.beginUserScroll(at: scrollView.contentOffset.y)
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard !isAssigningOffset, !isInstalling, layoutDepth == 0,
          session.isCurrentHost(self), session.isActive, !session.isDisposed else { return }
    let nativeGesture = scrollView.isTracking || scrollView.isDragging
      || scrollView.isDecelerating || isNativeScroll
    if !nativeGesture, !session.isUserScrolling,
       abs(scrollView.contentOffset.y - session.timeline.layout.originY) <= 0.01 { return }
    semanticAnchor = nil
    if !nativeGesture, !session.isUserScrolling {
      // UIKit also moves a scroll view for VoiceOver, status-bar taps, and
      // system paging without invoking the drag delegate callbacks.
      session.beginUserScroll(at: scrollView.contentOffset.y)
    }
    session.userScrolled(to: scrollView.contentOffset.y)
    guard session.isCurrentHost(self) else { return }
    if !nativeGesture, scrollView.contentOffset.y >= -0.01,
       scrollView.contentOffset.y <= session.timeline.layout.maximumOrigin + 0.01 {
      session.endUserScroll(at: scrollView.contentOffset.y)
    }
    installPresentation()
  }

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if session.isCurrentHost(self) { session.notifyDraggingEnded(willDecelerate: decelerate) }
    if !decelerate { finishNativeScroll() }
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    finishNativeScroll()
  }

  private func finishNativeScroll() {
    guard session.isCurrentHost(self), session.isActive else { return }
    isNativeScroll = false
    session.endUserScroll(at: scrollView.contentOffset.y)
    installPresentation()
  }

  // MARK: Keyboard

  private func configureKeyboardTracking() {
    if let keyboardObserver {
      NotificationCenter.default.removeObserver(keyboardObserver)
      self.keyboardObserver = nil
    }
    NSLayoutConstraint.deactivate(keyboardConstraints)
    keyboardConstraints = []
    keyboardProbe.removeFromSuperview()
    keyboardTransition = nil
    guard tracksKeyboard, let window else {
      if !tracksKeyboard { keyboardOcclusion = 0 }
      submitInsets(animation: .none, at: CACurrentMediaTime(), adjustment: .preserveAnchor)
      return
    }
    scrollView.keyboardDismissMode = .interactive
    addSubview(keyboardProbe)
    keyboardConstraints = [
      keyboardProbe.leadingAnchor.constraint(equalTo: leadingAnchor),
      keyboardProbe.widthAnchor.constraint(equalToConstant: 1),
      keyboardProbe.heightAnchor.constraint(equalToConstant: 1),
      // The window's guide: a view's own guide rests at that view's bottom, so
      // a list that stops short of the screen edge would see a shorter travel.
      keyboardProbe.topAnchor.constraint(equalTo: window.keyboardLayoutGuide.topAnchor),
    ]
    NSLayoutConstraint.activate(keyboardConstraints)
    keyboardObserver = NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
    ) { [weak self] note in
      let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
      let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? 7
      MainActor.assumeIsolated {
        self?.keyboardNote = (CACurrentMediaTime(), duration, curve)
      }
    }
  }

  /// The probe follows `keyboardLayoutGuide`. UIKit lays it out inside the
  /// keyboard's animation block for open/close and synchronously while an
  /// interactive dismissal drags the keyboard.
  private func keyboardGuideMoved() {
    guard session.isCurrentHost(self), keyboardProbe.superview === self else { return }
    let edge = keyboardProbe.frame.minY
    let previousEdge = lastKeyboardEdge ?? edge
    lastKeyboardEdge = edge
    let occlusion = max(0, bounds.maxY - edge)
    guard abs(occlusion - keyboardOcclusion) > 0.01 else { return }
    keyboardOcclusion = occlusion
    let now = CACurrentMediaTime()
    let inherited = UIView.inheritedAnimationDuration
    let note = keyboardNote.flatMap { now - $0.time < 0.25 ? $0 : nil }
    let duration = inherited > 0 ? inherited : (note?.duration ?? 0)
    if duration > 0, !scrollView.isTracking {
      keyboardTransition = .init(
        from: previousEdge, to: edge, end: now + duration + 0.25,
        followsSystemSpring: Self.keyboardUsesSystemSpring(duration: duration, curve: note?.curve ?? 7)
      )
      updateClock()
    } else {
      keyboardTransition = nil
      let native = scrollView.isTracking || scrollView.isDragging || isNativeScroll
      submitInsets(animation: .none, at: now, adjustment: native ? .nativeInput : .preserveAnchor)
    }
  }

  /// Curve 7 at 0.3832 s on iOS 26 is the system spring, the check Telegram
  /// makes. Other curves are followed by the keyboard's measured velocity.
  private static func keyboardUsesSystemSpring(duration: Double, curve: Int) -> Bool {
    guard curve == 7, #available(iOS 26.0, *) else { return false }
    return abs(duration - 0.3832) <= 0.0001
  }

  /// How far along the system spring the keyboard is at this progress.
  private static func systemSpringTime(atProgress progress: CGFloat) -> Double {
    var low = 0.0
    var high = 1.0
    for _ in 0 ..< 24 {
      let middle = (low + high) / 2
      if ChatListMotion.system.progress(after: middle) < progress { low = middle } else { high = middle }
    }
    return (low + high) / 2
  }

  /// Read the keyboard's presented edge and look ahead to the frame being
  /// rendered. Reading alone leaves the list one frame behind.
  private func followKeyboard(at targetTime: Double) {
    guard var transition = keyboardTransition else { return }
    let now = CACurrentMediaTime()
    guard now <= transition.end, let edge = keyboardProbe.layer.presentation()?.frame.minY else {
      submitOcclusion(max(0, bounds.maxY - transition.to), at: targetTime)
      keyboardTransition = nil
      return
    }
    let lead = max(0, targetTime - now)
    let span = transition.to - transition.from
    var predicted = edge
    if transition.followsSystemSpring, abs(span) > 0.5 {
      let progress = min(1, max(0, (edge - transition.from) / span))
      if progress > 0.0005 {
        let elapsed = Self.systemSpringTime(atProgress: progress)
        predicted = transition.from + span * ChatListMotion.system.progress(after: elapsed + lead)
      }
    } else if let last = transition.lastSample, now > last.time {
      predicted = edge + (edge - last.edge) / CGFloat(now - last.time) * CGFloat(lead)
    }
    let low = min(transition.from, transition.to)
    let high = max(transition.from, transition.to)
    submitOcclusion(max(0, bounds.maxY - min(high, max(low, predicted))), at: targetTime)
    transition.lastSample = (now, edge)
    keyboardTransition = abs(edge - transition.to) <= 0.5 ? nil : transition
  }

  private func submitOcclusion(_ occlusion: CGFloat, at time: Double) {
    let target = session.timeline.targetViewport
    session.updateViewport(
      TimelineViewport(width: target.width, height: target.height, topInset: topInset,
                       bottomInset: bottomAccessoryHeight + occlusion),
      displayScale: session.layoutContext.displayScale,
      environmentRevision: session.layoutContext.environmentRevision,
      animation: .none, at: time
    )
  }

  private func submitInsets(animation: ChatListAnimation, at time: Double, adjustment: ChatListViewportAdjustment) {
    guard session.isCurrentHost(self) else { return }
    let target = session.timeline.targetViewport
    let occlusion = tracksKeyboard ? keyboardOcclusion : 0
    session.updateViewport(
      TimelineViewport(width: target.width, height: target.height, topInset: topInset,
                       bottomInset: bottomAccessoryHeight + occlusion),
      displayScale: session.layoutContext.displayScale,
      environmentRevision: session.layoutContext.environmentRevision,
      animation: animation, at: time, viewportAdjustment: adjustment
    )
    updateClock()
  }

  // MARK: Reordering

  private func handleReorder(_ recognizer: UIGestureRecognizer) {
    guard session.isCurrentHost(self) else { return }
    let touchY = recognizer.location(in: self).y
    let time = CACurrentMediaTime()
    switch recognizer.state {
      case .began:
        guard let id = row(atViewportY: touchY, x: recognizer.location(in: self).x),
              session.beginReorder(id: id, touchY: touchY, at: time) else {
          recognizer.isEnabled = false
          recognizer.isEnabled = isReorderingEnabled
          return
        }
        liftedID = id
        seenReorderHops = session.timeline.reorderHops
        scrollView.isScrollEnabled = false
        liftFeedback.impactOccurred()
        if let resident = residents[id] {
          canvas.bringSubviewToFront(resident.slot)
          setLifted(true, slot: resident.slot)
          cellReorderStateChanged?(resident.slot.cell, true)
        }
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
    scrollView.isScrollEnabled = true
    if cancelled { session.cancelReorder(at: CACurrentMediaTime()) }
    else { session.endReorder(at: CACurrentMediaTime()) }
    if let resident = residents[id] {
      setLifted(false, slot: resident.slot)
      cellReorderStateChanged?(resident.slot.cell, false)
    }
    updateClock()
  }

  private func setLifted(_ lifted: Bool, slot: RowSlot) {
    guard reorderedRowHasShadow else { return }
    slot.clipsToBounds = !lifted
    slot.layer.shadowColor = UIColor.black.cgColor
    slot.layer.shadowOffset = .zero
    slot.layer.shadowRadius = 9
    let fade = CABasicAnimation(keyPath: "shadowOpacity")
    fade.fromValue = slot.layer.presentation()?.shadowOpacity ?? slot.layer.shadowOpacity
    fade.duration = 0.25
    slot.layer.shadowOpacity = lifted ? 0.35 : 0
    slot.layer.add(fade, forKey: "shadowOpacity")
  }

  private func row(atViewportY y: CGFloat, x: CGFloat) -> ID? {
    let layout = session.timeline.layout
    let point = CGPoint(x: x, y: y + layout.originY)
    let range = layout.visibleRows(in: CGRect(x: 0, y: point.y, width: layout.viewport.width, height: 0.5))
    return layout.rows[range].first { !$0.isExiting && $0.frame.contains(point) }?.row.id
  }

  // MARK: Presentation

  private func willRemove(_ events: [ChatListRemovalEvent<ID>]) {
    guard let willRemoveCell else { return }
    for event in events {
      guard let resident = residents[event.id], let item = session.item(for: event.id) else { continue }
      willRemoveCell(resident.slot.cell, item, event)
    }
  }

  private func captureBeforeApply(intent: TimelineIntent<ID>?) {
    guard session.isCurrentHost(self) else { return }
    guard intent == nil, case .reading = session.timeline.intent,
          !session.timeline.isNavigating,
          !session.isUserScrolling, !isNativeScroll,
          let captureCellAnchor else {
      semanticAnchor = nil
      return
    }
    let layout = session.timeline.layout
    let reading = layout.readingRect
    let range = layout.visibleRows(in: reading)
    let edge = session.anchorEdge
    let ordered = edge == .top ? Array(range) : Array(range.reversed())
    semanticAnchor = nil
    for index in ordered {
      let placement = layout.rows[index]
      guard !placement.isExiting, placement.row.canAnchor,
            let resident = residents[placement.row.id],
            let item = session.item(for: placement.row.id) else { continue }
      let localVisible = reading.intersection(placement.frame).offsetBy(
        dx: -placement.frame.minX, dy: -placement.frame.minY
      )
      guard !localVisible.isNull,
            let address = captureCellAnchor(resident.slot.cell, item, localVisible),
            address.localY.isFinite else { continue }
      semanticAnchor = .init(
        id: placement.row.id,
        cellAnchor: address,
        viewportY: edge == .top
          ? placement.frame.minY + address.localY - reading.minY
          : layout.originY + layout.viewport.height - layout.viewport.bottomInset - placement.frame.minY - address.localY,
        edge: edge,
        location: nil,
        needsResolution: true,
        expectedIntent: nil
      )
      break
    }
  }

  private func installPresentation() {
    guard session.isCurrentHost(self) || session.isDisposed else { updateClock(); return }
    guard !session.isDisposed else { clearResidents(); displayClock.stop(); return }
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
    if liftedID != nil, session.timeline.reorderHops != seenReorderHops {
      seenReorderHops = session.timeline.reorderHops
      hopFeedback.selectionChanged()
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    UIView.performWithoutAnimation {
      // Keep the installed width from the prepared presentation while the
      // adapter prepares a replacement for a new bounds/environment context.
      let canvasSize = CGSize(width: layout.viewport.width, height: layout.contentHeight)
      if canvas.frame.size != canvasSize {
        canvas.frame = CGRect(origin: .zero, size: canvasSize)
      }
      if scrollView.contentSize != canvasSize { scrollView.contentSize = canvasSize }
      if scrollView.contentInset != .zero { scrollView.contentInset = .zero }
      let indicatorInsets = UIEdgeInsets(
        top: layout.viewport.topInset, left: 0,
        bottom: layout.viewport.bottomInset, right: 0
      )
      if scrollView.verticalScrollIndicatorInsets != indicatorInsets {
        scrollView.verticalScrollIndicatorInsets = indicatorInsets
      }
      if scrollView.contentOffset.x != 0 { assignOffset(y: scrollView.contentOffset.y) }
      if abs(scrollView.contentOffset.y - layout.originY) > 0.01 {
        // On a prepared prepend/edit or inset change, compensate even during
        // a drag or deceleration. Native input callbacks already synchronize
        // the timeline origin, so only a geometry transaction has a delta.
        // The timeline carries native rubber-band displacement relative to
        // its moving boundary, including interactive keyboard occlusion.
        assignOffset(y: layout.originY)
      }
      layoutOverscrollViews(contentHeight: layout.contentHeight, width: layout.viewport.width)
      let actualOrigin = scrollView.contentOffset.y
      materialize(layout: layout, visibleRect: CGRect(
        x: 0, y: actualOrigin,
        width: layout.viewport.width, height: scrollView.bounds.height
      ))
      refineSemanticAnchor(in: layout)
      presentOverlays?(overlayView, session.timeline.layout)
    }
    CATransaction.commit()
    updateClock()
    scheduleDidPresent()
  }

  private func materialize(
    layout: TimelineLayout<ID>, visibleRect: CGRect, presentExisting: Bool = true
  ) {
    let guardRect = visibleRect.insetBy(dx: 0, dy: -configuration.overscan)
    let range = layout.visibleRows(in: guardRect)
    var required = Set(layout.rows[range].map(\.row.id))
    for id in pinnedIDs where layout.placement(for: id) != nil { required.insert(id) }
    if let lifted = layout.reorderingID { required.insert(lifted) }
    required.formUnion(layout.departingIDs)
    let focusedAccessibilityView = accessibilityFocusedView()
    for (id, resident) in residents where layout.placement(for: id) != nil {
      let cell = resident.slot.cell
      if containsFirstResponder(cell)
        || focusedAccessibilityView === cell
        || focusedAccessibilityView?.isDescendant(of: cell) == true { required.insert(id) }
    }
    if let semanticAnchor, semanticAnchor.needsResolution,
       layout.placement(for: semanticAnchor.id) != nil { required.insert(semanticAnchor.id) }

    for id in Array(residents.keys) where !required.contains(id) {
      evict(id)
    }
    var placements = Array(layout.rows[range])
    let visibleIDs = Set(placements.map(\.row.id))
    for id in required.subtracting(visibleIDs) {
      if let placement = layout.placement(for: id) { placements.append(placement) }
    }
    for placement in placements {
      let id = placement.row.id
      guard let item = session.item(for: id) else { continue }
      let context = session.snapshot?.context ?? session.layoutContext
      if let current = residents[id], current.reuseIdentifier != item.reuseIdentifier,
         !placement.isExiting { evict(id) }
      let resident: Resident
      let wasResident = residents[id] != nil
      if var existing = residents[id] {
        if !placement.isExiting && (existing.revision != item.revision || existing.context != context) {
          existing.revision = item.revision
          existing.context = context
          existing.reuseIdentifier = item.reuseIdentifier
          existing.slot.cell.frame = CGRect(x: 0, y: 0, width: context.width, height: item.height)
          bindCell?(existing.slot.cell, item, context)
          residents[id] = existing
        }
        resident = residents[id]!
      } else {
        // Exiting rows retain their former cell and prepared width. They are
        // never newly created from a replacement snapshot's context.
        if placement.isExiting { continue }
        let reused = reusePool[item.reuseIdentifier]?.popLast()
        let cell = makeCell(item, reused)
        let slot = RowSlot(cell: cell)
        slot.frame = placement.frame
        cell.frame = CGRect(x: 0, y: 0, width: context.width, height: item.height)
        canvas.addSubview(slot)
        let created = Resident(
          slot: slot, revision: item.revision, context: context,
          reuseIdentifier: item.reuseIdentifier
        )
        residents[id] = created
        bindCell?(cell, item, context)
        if case let .entering(_, insertion) = placement.phase { didInsertCell?(cell, item, insertion) }
        resident = created
      }
      resident.slot.frame = placement.frame
      resident.slot.alpha = placement.opacity
      resident.slot.isHidden = hiddenIDs.contains(id)
      resident.slot.isUserInteractionEnabled = !placement.isExiting
      if placement.isReordering, canvas.subviews.last !== resident.slot { canvas.bringSubviewToFront(resident.slot) }
      if presentExisting || !wasResident { presentCell?(resident.slot.cell, placement) }
      if let updateCellVisibility {
        let visibility = layout.visibility(for: id)
        if residents[id]?.visibility != visibility {
          residents[id]?.visibility = visibility
          updateCellVisibility(resident.slot.cell, visibility)
        }
      }
    }
    updateAccessibilityOrder(in: layout)
  }

  private func updateAccessibilityOrder(in layout: TimelineLayout<ID>) {
    let ordered = residents.compactMap { id, resident -> (Int, ID, RowSlot)? in
      guard let index = layout.index(for: id), !layout.rows[index].isExiting else { return nil }
      return (index, id, resident.slot)
    }.sorted { $0.0 < $1.0 }
    let ids = ordered.map { $0.1 }
    let slots = ordered.map { ObjectIdentifier($0.2) }
    guard ids != accessibilityOrder || slots != accessibilitySlotIDs else { return }
    accessibilityOrder = ids
    accessibilitySlotIDs = slots
    canvas.accessibilityElements = ordered.map { $0.2 as Any }
  }

  private func refineSemanticAnchor(in layout: TimelineLayout<ID>) {
    guard session.isCurrentHost(self) else { return }
    guard var anchor = semanticAnchor, !session.isUserScrolling, !isNativeScroll,
          !session.timeline.isNavigating,
          let placement = layout.placement(for: anchor.id), !placement.isExiting,
          let resident = residents[anchor.id] else { return }
    if let expectedIntent = anchor.expectedIntent,
       expectedIntent != session.timeline.intent {
      semanticAnchor = nil
      return
    }
    if anchor.needsResolution {
      guard let item = session.item(for: anchor.id),
            let location = resolveCellAnchor?(resident.slot.cell, item, anchor.cellAnchor),
            location.localY(in: placement.row.elements) != nil else {
        semanticAnchor = nil
        return
      }
      anchor.location = location
      anchor.needsResolution = false
    }
    guard let location = anchor.location,
          session.isCurrentHost(self),
          session.refineAnchor(row: anchor.id, location: location, viewportY: anchor.viewportY, edge: anchor.edge) else {
      semanticAnchor = nil
      return
    }
    anchor.expectedIntent = session.timeline.intent
    semanticAnchor = anchor
    let corrected = session.timeline.layout
    if abs(scrollView.contentOffset.y - corrected.originY) > 0.01 {
      assignOffset(y: corrected.originY)
      // The correction may reveal a new edge. Existing cells already received
      // this frame's presentation and must not be rebound within this tick.
      materialize(layout: corrected, visibleRect: CGRect(
        x: 0, y: corrected.originY, width: corrected.viewport.width,
        height: scrollView.bounds.height
      ), presentExisting: false)
    }
  }

  private func assignOffset(y: CGFloat) {
    isAssigningOffset = true
    scrollView.contentOffset = CGPoint(x: 0, y: y)
    isAssigningOffset = false
  }

  private func updateOverscrollViews() {
    topOverscrollView.backgroundColor = topOverscrollColor
    topOverscrollView.isHidden = topOverscrollColor == nil
    bottomOverscrollView.backgroundColor = bottomOverscrollColor
    bottomOverscrollView.isHidden = bottomOverscrollColor == nil
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

  private func evict(_ id: ID) {
    guard let resident = residents.removeValue(forKey: id) else { return }
    // A focused row is kept resident while it merely leaves the viewport.
    // Logical removal or a cell-kind replacement reaches this path, so end
    // editing before the native cell can enter another row's reuse pool.
    if containsFirstResponder(resident.slot.cell) {
      resident.slot.cell.endEditing(true)
    }
    if resident.visibility != .hidden { updateCellVisibility?(resident.slot.cell, .hidden) }
    resident.slot.removeFromSuperview()
    resident.slot.cell.removeFromSuperview()
    recycleCell?(resident.slot.cell)
    if (reusePool[resident.reuseIdentifier]?.count ?? 0) < configuration.maximumReusableCellsPerKind {
      reusePool[resident.reuseIdentifier, default: []].append(resident.slot.cell)
    }
  }

  private func clearResidents() {
    for id in Array(residents.keys) { evict(id) }
    reusePool.removeAll()
    accessibilityOrder.removeAll()
    accessibilitySlotIDs.removeAll()
    canvas.accessibilityElements = nil
    semanticAnchor = nil
  }

  private func trimReusePool() {
    for key in Array(reusePool.keys) {
      reusePool[key] = Array(reusePool[key, default: []].suffix(configuration.maximumReusableCellsPerKind))
    }
  }

  private func containsFirstResponder(_ view: UIView) -> Bool {
    view.isFirstResponder || view.subviews.contains(where: containsFirstResponder)
  }

  private func accessibilityFocusedView() -> UIView? {
    guard UIAccessibility.isVoiceOverRunning else { return nil }
    var focused = UIAccessibility.focusedElement(using: nil) as AnyObject?
    for _ in 0 ..< 8 {
      if let view = focused as? UIView { return view }
      guard let element = focused as? UIAccessibilityElement else { break }
      focused = element.accessibilityContainer as AnyObject?
    }
    return nil
  }

  private func updateClock() {
    if configuration.usesAutomaticDisplayClock && window != nil
      && session.isCurrentHost(self) && session.isActive
      && (session.needsDisplayFrames || keyboardTransition != nil) {
      displayClock.start()
    } else {
      displayClock.stop()
    }
  }

  private func scheduleDidPresent() {
    guard !didPresentScheduled else { return }
    didPresentScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.didPresentScheduled = false
      guard self.session.isCurrentHost(self) else { return }
      self.session.historyTriggerDistance = self.configuration.historyTriggerDistance
      self.session.didPresent()
    }
  }
}

/// A non-generic Objective-C target avoids retaining the host through a display link.
@MainActor
private final class DisplayClock {
  @MainActor private final class Target: NSObject {
    weak var owner: DisplayClock?
    /// Present the state for the frame being rendered, not the one on screen.
    @objc func tick(_ link: CADisplayLink) { owner?.onFrame?(link.targetTimestamp) }
  }

  var onFrame: ((Double) -> Void)?
  private let target = Target()
  private var link: CADisplayLink?
  var isRunning: Bool { link != nil }

  init() { target.owner = self }

  func start() {
    guard link == nil else { return }
    let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    self.link = link
    link.add(to: .main, forMode: .common)
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  isolated deinit { link?.invalidate() }
}
#endif
