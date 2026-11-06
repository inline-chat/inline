import CoreGraphics
import Foundation

public enum ChatListApplyResult: Equatable, Sendable {
  case applied(generation: UInt64)
  case deferred
}

/// The same presentation owner is used by both native hosts and deterministic
/// labs. It has no native views, app model, renderer, database, or network work.
@MainActor
public final class ChatListSession<ID: Hashable & Sendable, Content> {
  public private(set) var timeline: MessageTimeline<ID>
  public private(set) var snapshot: ChatListSnapshot<ID, Content>?
  public private(set) var generation: UInt64 = 0
  public private(set) var isUserScrolling = false
  public private(set) var isDisposed = false
  public private(set) var isActive = true
  public private(set) var layoutContext: ChatListLayoutContext
  public var onWillApply: ((TimelineIntent<ID>?) -> Void)?
  public var onPresentationChanged: (() -> Void)?
  public var onPresentation: ((ChatListPresentationEvent<ID>) -> Void)?
  public var onHistoryDemand: ((ChatListEdge) -> Void)?
  public var onNeedsSnapshot: ((ChatListLayoutContext) -> Void)?
  public var onPreparationError: ((Error) -> Void)?
  public var historyTriggerDistance: CGFloat = 240

  /// Scroll lifecycle and direction (Telegram's dragging/scrolling callbacks).
  public var onScrollEvent: ((ChatListScrollEvent) -> Void)?
  /// Distances to the content edges and on-screen content movement per frame.
  public var onContentOffsetChanged: ((ChatListContentOffset) -> Void)?
  /// Rows inside the usable viewport changed (read marks, autoplay, prefetch).
  public var onVisibleRangeChanged: ((ChatListVisibleRange<ID>) -> Void)?
  /// A row is about to animate out, with its presented frame (dust effects).
  public var onWillRemove: ((ChatListRemovalEvent<ID>) -> Void)?
  /// Return true for rows that may be lifted and moved. Nil disables reordering.
  public var canReorder: ((ID) -> Bool)?
  /// A lifted row was dropped into a new slot. Publish the new order next.
  public var onReorder: ((ChatListReorder<ID>) -> Void)?
  /// The lifted row changed slot while dragging (haptics).
  public var onReorderHop: ((ID) -> Void)?
  /// Seconds after scrolling stops before idle-hiding decorations fade.
  /// Telegram holds its floating date header for 0.3 s.
  public var decorationIdleDelay: Double = 0.3

  private let now: @MainActor () -> Double
  private weak var hostOwner: AnyObject?
  private var hostWillApply: ((TimelineIntent<ID>?) -> Void)?
  private var hostPresentationChanged: (() -> Void)?
  private var hostWillRemove: (([ChatListRemovalEvent<ID>]) -> Void)?
  private var needsSnapshotOnActivation = false
  private var pendingNavigation: Navigation?
  private var viewport: TimelineViewport
  private var installed: [ID: ChatListItem<ID, Content>] = [:]
  private var retiring: [ID: ChatListItem<ID, Content>] = [:]
  private var pending: Pending?
  private var applying = false
  private var deferringPresentation = false
  private var overscrolling = false
  private var demandedOlder = false
  private var demandedNewer = false
  private var preparationRevision: UInt64 = 0
  private var inputGeneration: UInt64 = 0
  private var preparationTask: Task<Void, Never>?
  private var preparations = TimelinePreparationQueue<PreparationKey, Preparation>()
  private var staging: Staging?
  private var stagingToken: UInt64 = 0
  private var animatesMovesOnNextApply = false
  private var seenNavigationCompletions: UInt64 = 0
  private var seenReorderHops: UInt64 = 0
  private var lastDirection: ChatListScrollDirection?
  private var lastReference: (id: ID, y: CGFloat)?
  private var lastContentOffset: ChatListContentOffset?
  private var lastVisibleRange: ChatListVisibleRange<ID>?
  private var lastScrollActivity: Double = -.infinity
  private var idleOpacities: [String: TimelineSpring] = [:]
  private var idleClock: Double?

  private struct Pending {
    let snapshot: ChatListSnapshot<ID, Content>
    let intent: TimelineIntent<ID>?
    let animation: ChatListAnimation
    let transitions: ChatListTransitions<ID>
    let direction: ChatListScrollDirection?
  }

  private struct Navigation {
    let intent: TimelineIntent<ID>
    let animation: ChatListAnimation
    let direction: ChatListScrollDirection?
  }

  private struct PreparationKey: Equatable {
    let context: ChatListLayoutContext
    let identities: [ID]
  }

  private struct Preparation {
    let operation: @MainActor (ChatListLayoutContext) async throws -> ChatListSnapshot<ID, Content>
    let intent: TimelineIntent<ID>?
    let animation: ChatListAnimation
    let inputGeneration: UInt64
    let completion: (@MainActor () -> Void)?
  }

  private struct Staging {
    let token: UInt64
    var older: Bool
    var newer: Bool
  }

  public init(
    viewport: TimelineViewport = .init(width: 0, height: 0),
    now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.now = now
    self.viewport = viewport
    timeline = .init(viewport: viewport)
    layoutContext = .init(width: viewport.width)
  }

  /// Sticky decorations on the presented frame, with idle fading applied.
  public var decorationPlacements: [ChatListDecorationPlacement] {
    guard let snapshot else { return [] }
    return snapshot.decorations.compactMap { decoration in
      guard let placement = decoration.placement(in: timeline.layout) else { return nil }
      guard decoration.hidesWhenIdle, let idle = idleOpacities[decoration.id] else { return placement }
      return placement.withOpacity(placement.opacity * min(1, max(0, idle.value)))
    }
  }

  /// Hosts keep their display clock running while this is true.
  public var needsDisplayFrames: Bool {
    timeline.isAnimating || idleOpacities.values.contains { !$0.isSettled } || awaitsIdleDeadline
  }

  public var isReordering: Bool { timeline.isReordering }

  /// Edge for the next implicit commit, including a viewport supplied to apply.
  /// Hosts capture a content point from that edge before replacing any cells.
  public var anchorEdge: TimelineAnchorEdge {
    timeline.anchorEdge(for: viewport)
  }

  public func item(for id: ID) -> ChatListItem<ID, Content>? { installed[id] ?? retiring[id] }

  /// One native host owns presentation. Replacing it cannot let the old host's
  /// teardown remove the replacement's callbacks. App observers are separate.
  public func attachHost(
    owner: AnyObject, willApply: @escaping (TimelineIntent<ID>?) -> Void,
    presentationChanged: @escaping () -> Void,
    willRemove: (([ChatListRemovalEvent<ID>]) -> Void)? = nil
  ) {
    let replacingHost = hostOwner != nil && hostOwner !== owner
    let previousPresentationChanged = hostPresentationChanged
    hostOwner = owner
    hostWillApply = willApply
    hostPresentationChanged = presentationChanged
    // Native hosts receive removals before the replacement is installed.
    hostWillRemove = willRemove
    // Revoke the former host before notifying it, so it stops its native clock
    // without changing the replacement's activation, viewport, or input.
    if replacingHost { finishRevokedHostScroll() }
    previousPresentationChanged?()
  }

  /// Native hosts must check this at every callback/async entry and again after
  /// calling application code before mutating the session. Apps retain direct
  /// session control; replacing a host revokes only the former native adapter.
  public func isCurrentHost(_ owner: AnyObject) -> Bool {
    !isDisposed && hostOwner === owner
  }

  public func detachHost(owner: AnyObject) {
    guard hostOwner === owner else { return }
    let previousPresentationChanged = hostPresentationChanged
    hostOwner = nil
    hostWillApply = nil
    hostPresentationChanged = nil
    hostWillRemove = nil
    finishRevokedHostScroll()
    previousPresentationChanged?()
  }

  private func finishRevokedHostScroll() {
    if timeline.isReordering { timeline.cancelReorder(at: now()) }
    guard isUserScrolling || overscrolling else { return }
    // The outgoing host cannot deliver completion after revocation. Settle its
    // phase before calling observers that may start input on the new host.
    let origin = min(timeline.layout.maximumOrigin, max(0, timeline.layout.originY))
    timeline.endUserScroll(at: origin, canFollowLatest: snapshot?.history.isAtLiveEnd == true)
    isUserScrolling = false
    overscrolling = false
    if isActive, !applying { finishDeferred(at: now()) }
  }

  private func presentationChanged() {
    guard !deferringPresentation else { return }
    if hostOwner != nil { hostPresentationChanged?() }
    onPresentationChanged?()
    publishFrameEvents()
  }

  /// Atomically install exact geometry, an optional new viewport, and intent.
  /// Supplying a viewport also adopts the snapshot's full layout context.
  /// A direct publication supersedes outstanding asynchronous preparation.
  /// `scrollTo` places a row (overriding `intent`); with a direction the new
  /// window slides in over one screen, as a far jump in Telegram.
  @discardableResult
  public func apply(
    _ snapshot: ChatListSnapshot<ID, Content>, intent: TimelineIntent<ID>? = nil,
    animation: ChatListAnimation = .animated, at time: Double,
    viewport newViewport: TimelineViewport? = nil,
    viewportAdjustment: ChatListViewportAdjustment = .preserveAnchor,
    transitions: ChatListTransitions<ID> = .init(),
    scrollTo request: ChatListScrollRequest<ID>? = nil
  ) throws -> ChatListApplyResult {
    guard !isDisposed else { throw ChatListError.disposed }
    guard !applying else { throw ChatListError.reentrantTransaction }
    try snapshot.validate()
    try validate(intent)
    if let newViewport {
      guard newViewport.height.isFinite, newViewport.height >= 0,
            newViewport.topInset.isFinite, newViewport.topInset >= 0,
            newViewport.bottomInset.isFinite, newViewport.bottomInset >= 0 else { throw ChatListError.invalidGeometry }
      guard newViewport.width == snapshot.context.width else { throw ChatListError.staleContext }
    } else {
      guard snapshot.context == layoutContext else { throw ChatListError.staleContext }
    }
    cancelPreparation()
    if let newViewport {
      viewport = newViewport
      layoutContext = snapshot.context
    }
    var resolvedIntent = intent
    if let request {
      let heights = Dictionary(snapshot.items.map { ($0.id, $0.height) }, uniquingKeysWith: { first, _ in first })
      resolvedIntent = self.intent(for: request, height: heights[request.id]) ?? intent
    }
    pending = nil
    needsSnapshotOnActivation = false
    if resolvedIntent != nil { pendingNavigation = nil }
    return try install(
      snapshot, intent: resolvedIntent, animation: animation, at: time,
      viewportAdjustment: viewportAdjustment, transitions: transitions,
      direction: request?.direction
    )
  }

  private func install(
    _ snapshot: ChatListSnapshot<ID, Content>, intent: TimelineIntent<ID>?,
    animation: ChatListAnimation, at time: Double,
    viewportAdjustment: ChatListViewportAdjustment = .preserveAnchor,
    transitions: ChatListTransitions<ID> = .init(),
    direction: ChatListScrollDirection? = nil
  ) throws -> ChatListApplyResult {
    guard !isDisposed else { throw ChatListError.disposed }
    guard !applying else { throw ChatListError.reentrantTransaction }
    try snapshot.validate()
    try validate(intent)
    guard snapshot.context == layoutContext else { throw ChatListError.staleContext }
    if overscrolling || !isActive || timeline.isReordering {
      pending = .init(snapshot: snapshot, intent: intent, animation: animation,
                      transitions: transitions, direction: direction)
      updateInstalledViewport(animation: animation, at: time, adjustment: viewportAdjustment)
      return .deferred
    }
    if isUserScrolling, let intent {
      pendingNavigation = .init(intent: intent, animation: animation, direction: direction)
    }
    let intent = isUserScrolling ? nil : intent
    let applyingHost = hostOwner
    applying = true
    defer {
      applying = false
      // A callback can transfer ownership and reject this publication. The old
      // host's queued navigation/content still needs to drain after we unwind.
      if !isDisposed, isActive, hostOwner !== applyingHost,
         !isUserScrolling, !overscrolling, pending != nil || pendingNavigation != nil {
        finishDeferred(at: now())
      }
    }
    func validatePublication() throws {
      guard !isDisposed else { throw ChatListError.disposed }
      guard snapshot.context == layoutContext else { throw ChatListError.staleContext }
      guard hostOwner === applyingHost else { throw ChatListError.reentrantTransaction }
    }
    if hostOwner != nil { hostWillApply?(intent) }
    try validatePublication()
    onWillApply?(intent)
    try validatePublication()
    // Callbacks can pause the session or start native bounce as well as resize.
    // None of those may install a replacement outside its admission boundary.
    if overscrolling || !isActive {
      pending = .init(snapshot: snapshot, intent: intent, animation: animation,
                      transitions: transitions, direction: direction)
      return .deferred
    }
    let next = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
    let removals = removalEvents(leaving: next, animation: animation, transitions: transitions)
    if !removals.isEmpty {
      if hostOwner != nil { hostWillRemove?(removals) }
      for event in removals { onWillRemove?(event) }
      try validatePublication()
    }
    for (id, item) in installed where next[id] == nil { retiring[id] = item }
    installed = next
    let changedWidth = self.snapshot?.context.width != snapshot.context.width
    if self.snapshot?.items.first?.id != snapshot.items.first?.id
      || self.snapshot?.history.hasOlder != snapshot.history.hasOlder { demandedOlder = false }
    if self.snapshot?.items.last?.id != snapshot.items.last?.id
      || self.snapshot?.history.hasNewer != snapshot.history.hasNewer { demandedNewer = false }
    self.snapshot = snapshot
    needsSnapshotOnActivation = false
    generation &+= 1
    var transitions = transitions
    if animatesMovesOnNextApply {
      transitions.animatesMoves = true
      animatesMovesOnNextApply = false
    }
    // Content compensation is independent of native-owned viewport movement.
    // Apply the data at the previous viewport first, then adopt the new insets
    // without a second displacement. Publish only the final compound state.
    var contentViewport = viewport
    if viewportAdjustment == .nativeInput {
      timeline.stopInsetMotionAtPresentation()
      contentViewport = timeline.layout.viewport
      contentViewport.width = viewport.width
    }
    timeline.apply(
      rows: snapshot.items.map(\.geometry), viewport: contentViewport, intent: intent,
      motion: changedWidth ? nil : animation.motion, transitions: transitions,
      entering: changedWidth ? nil : direction, at: time
    )
    if viewportAdjustment == .nativeInput {
      timeline.resize(viewport: viewport, motion: nil, at: time, preservingNativeOrigin: true)
      updateOverscrollState()
    }
    retiring = retiring.filter { timeline.layout.placement(for: $0.key)?.isExiting == true }
    presentationChanged()
    return .applied(generation: generation)
  }

  private func removalEvents(
    leaving next: [ID: ChatListItem<ID, Content>], animation: ChatListAnimation,
    transitions: ChatListTransitions<ID>
  ) -> [ChatListRemovalEvent<ID>] {
    guard hostWillRemove != nil || onWillRemove != nil else { return [] }
    let layout = timeline.layout
    return installed.keys.compactMap { id in
      guard next[id] == nil, let placement = layout.placement(for: id), !placement.isExiting else { return nil }
      return .init(
        id: id, frame: placement.frame.offsetBy(dx: 0, dy: -layout.originY),
        removal: animation.isAnimated ? transitions.removal(for: id) : .none
      )
    }
  }

  /// Width changes keep the installed exact-width canvas until its replacement
  /// arrives. Height and occlusions can change immediately on the same clock.
  /// `time` is when the change began; a keyboard transition passes its own
  /// notification time and curve so the list moves on the keyboard's frames.
  public func updateViewport(
    _ viewport: TimelineViewport, displayScale: CGFloat = 1, environmentRevision: UInt64 = 0,
    animation: ChatListAnimation = .none, at time: Double,
    viewportAdjustment: ChatListViewportAdjustment = .preserveAnchor
  ) {
    guard !isDisposed else { return }
    guard displayScale.isFinite, displayScale > 0 else {
      onPreparationError?(ChatListError.invalidContext)
      return
    }
    let viewport = TimelineViewport(width: viewport.width, height: viewport.height,
                                    topInset: viewport.topInset, bottomInset: viewport.bottomInset)
    self.viewport = viewport
    let next = ChatListLayoutContext(
      width: viewport.width, displayScale: displayScale, environmentRevision: environmentRevision
    )
    let changed = next != layoutContext
    if changed {
      layoutContext = next
      cancelPreparation()
      pending = nil
    }
    updateInstalledViewport(animation: animation, at: time, adjustment: viewportAdjustment)
    if changed, next.width > 0 { onNeedsSnapshot?(next) }
  }

  private func updateInstalledViewport(
    animation: ChatListAnimation, at time: Double,
    adjustment: ChatListViewportAdjustment = .preserveAnchor
  ) {
    guard isActive else { return }
    var installedViewport = viewport
    if let snapshot { installedViewport.width = snapshot.context.width }
    if timeline.targetViewport != installedViewport
      || (adjustment == .nativeInput && timeline.layout.viewport != installedViewport) {
      timeline.resize(
        viewport: installedViewport, motion: animation.motion, at: time,
        preservingNativeOrigin: adjustment == .nativeInput
      )
      if adjustment == .nativeInput { updateOverscrollState() }
      presentationChanged()
    }
  }

  private func updateOverscrollState() {
    let origin = timeline.layout.originY
    overscrolling = origin < -0.01 || origin > timeline.layout.maximumOrigin + 0.01
  }

  /// A package-owned active/newest-pending queue. The provider returns exact
  /// prepared snapshots and may use its own actor for expensive cell layout.
  /// Compatible streaming makes progress; changed identity order/context fences
  /// stale work. No measurement is performed in a scroll or cell-binding path.
  public func requestPreparation(
    identities: [ID], intent: TimelineIntent<ID>? = nil, animation: ChatListAnimation = .animated,
    superseding: Bool = false,
    prepare: @escaping @MainActor (ChatListLayoutContext) async throws -> ChatListSnapshot<ID, Content>
  ) {
    staging = nil
    enqueuePreparation(identities: identities, intent: intent, animation: animation,
                       superseding: superseding, completion: nil, prepare: prepare)
  }

  private func enqueuePreparation(
    identities: [ID], intent: TimelineIntent<ID>?, animation: ChatListAnimation,
    superseding: Bool, completion: (@MainActor () -> Void)?,
    prepare: @escaping @MainActor (ChatListLayoutContext) async throws -> ChatListSnapshot<ID, Content>
  ) {
    guard !isDisposed, layoutContext.width > 0 else { return }
    guard isActive else { needsSnapshotOnActivation = true; return }
    if superseding {
      let currentStaging = staging
      cancelPreparation()
      staging = currentStaging
    }
    preparationRevision &+= 1
    let request = TimelinePreparationQueue<PreparationKey, Preparation>.Request(
      revision: preparationRevision,
      context: .init(context: layoutContext, identities: identities),
      snapshot: .init(operation: prepare, intent: intent, animation: animation,
                      inputGeneration: inputGeneration, completion: completion)
    )
    switch preparations.submit(request) {
      case let .start(request):
        preparationTask?.cancel()
        start(request)
      case .coalesced: break
    }
  }

  private func start(_ request: TimelinePreparationQueue<PreparationKey, Preparation>.Request) {
    guard preparations.active?.revision == request.revision else { return }
    preparationTask = Task { @MainActor [weak self] in
      do {
        let result = try await request.snapshot.operation(request.context.context)
        try Task.checkCancellation()
        guard let self, !isDisposed, isActive,
              preparations.active?.revision == request.revision else { return }
        guard result.items.map(\.id) == request.context.identities,
              result.context == request.context.context else { throw ChatListError.staleContext }
        // User input revokes a prepared navigation, not its valid content.
        let intent = request.snapshot.inputGeneration == inputGeneration ? request.snapshot.intent : nil
        _ = try install(result, intent: intent, animation: request.snapshot.animation, at: now())
        finishPreparation(request.revision)
        request.snapshot.completion?()
      } catch {
        guard let self, preparations.active?.revision == request.revision else { return }
        if !(error is CancellationError) { onPreparationError?(error) }
        finishPreparation(request.revision)
      }
    }
  }

  private func finishPreparation(_ revision: UInt64) {
    guard case let .accepted(next) = preparations.finish(revision: revision) else { return }
    preparationTask = nil
    if let next { start(next) }
  }

  /// Prepare a large window in stages, as Telegram lays out only near the
  /// visible range: rows around `focus` (or the newest rows) publish first, then
  /// older and newer rows join in chunks with the reading anchor preserved.
  /// Every published row still has exact geometry. History demand for an edge
  /// waits until that edge's staged rows are installed.
  public func requestStagedPreparation(
    identities: [ID], focus: ID? = nil, initialCount: Int = 40, chunkCount: Int = 80,
    intent: TimelineIntent<ID>? = nil, animation: ChatListAnimation = .none,
    history: ChatListHistoryAvailability = .init(),
    decorations: @escaping @MainActor ([ID]) -> [ChatListDecoration<ID>] = { _ in [] },
    prepareRows: @escaping @MainActor ([ID], ChatListLayoutContext) async throws -> [ChatListItem<ID, Content>]
  ) {
    guard !identities.isEmpty else { return }
    let focusIndex = focus.flatMap { identities.firstIndex(of: $0) } ?? identities.count - 1
    let initial = max(1, initialCount)
    let chunk = max(1, chunkCount)
    var lower = max(0, focusIndex - (focus == nil ? initial - 1 : initial / 2))
    var upper = min(identities.count - 1, lower + initial - 1)
    lower = max(0, min(lower, upper - initial + 1))
    var ranges = [lower ... upper]
    while lower > 0 || upper < identities.count - 1 {
      if lower > 0 { lower = max(0, lower - chunk) }
      if upper < identities.count - 1 { upper = min(identities.count - 1, upper + chunk) }
      ranges.append(lower ... upper)
    }
    stagingToken &+= 1
    let token = stagingToken
    var cache: [ID: ChatListItem<ID, Content>] = [:]
    var cacheContext: ChatListLayoutContext?

    func stage(_ index: Int) {
      guard index < ranges.count else { staging = nil; return }
      let range = ranges[index]
      let ids = Array(identities[range])
      let isLast = index == ranges.count - 1
      let older = range.lowerBound > 0
      let newer = range.upperBound < identities.count - 1
      enqueuePreparation(
        identities: ids, intent: index == 0 ? intent : nil,
        animation: index == 0 ? animation : .none, superseding: index == 0,
        completion: { [weak self] in
          guard let self, staging?.token == token else { return }
          if isLast { staging = nil } else {
            staging = .init(token: token, older: older, newer: newer)
            stage(index + 1)
          }
        },
        prepare: { context in
          if cacheContext != context {
            cache.removeAll()
            cacheContext = context
          }
          let missing = ids.filter { cache[$0] == nil }
          if !missing.isEmpty {
            for item in try await prepareRows(missing, context) { cache[item.id] = item }
          }
          let items = try ids.map { id -> ChatListItem<ID, Content> in
            guard let item = cache[id] else { throw ChatListError.staleContext }
            return item
          }
          return ChatListSnapshot(
            context: context, items: items,
            history: .init(
              hasOlder: older || history.hasOlder, hasNewer: newer || history.hasNewer,
              isAtLiveEnd: !newer && history.isAtLiveEnd
            ),
            decorations: decorations(ids)
          )
        }
      )
      if index == 0 { staging = .init(token: token, older: older, newer: newer) }
    }
    stage(0)
  }

  private func validate(_ intent: TimelineIntent<ID>?) throws {
    if case let .reading(anchor) = intent,
       !anchor.localY.isFinite || !anchor.viewportY.isFinite {
      throw ChatListError.invalidGeometry
    }
  }

  public func cancelPreparation() {
    preparationTask?.cancel()
    preparationTask = nil
    preparations.cancel()
    staging = nil
  }

  public func navigate(to intent: TimelineIntent<ID>, animation: ChatListAnimation = .animated, at time: Double) {
    navigate(to: intent, animation: animation, direction: nil, at: time)
  }

  /// Place a row in the installed window, as Telegram's `scrollToItem`.
  public func scroll(
    to request: ChatListScrollRequest<ID>, animation: ChatListAnimation = .animated, at time: Double
  ) {
    guard let intent = intent(for: request, height: installed[request.id]?.height) else { return }
    navigate(to: intent, animation: animation, direction: request.direction, at: time)
  }

  private func navigate(
    to intent: TimelineIntent<ID>, animation: ChatListAnimation,
    direction: ChatListScrollDirection?, at time: Double
  ) {
    guard !isDisposed else { return }
    do { try validate(intent) } catch { onPreparationError?(error); return }
    inputGeneration &+= 1
    if let pending {
      self.pending = .init(snapshot: pending.snapshot, intent: nil, animation: pending.animation,
                           transitions: pending.transitions, direction: nil)
    }
    if isUserScrolling || overscrolling || !isActive || timeline.isReordering {
      pendingNavigation = .init(intent: intent, animation: animation, direction: direction)
      return
    }
    pendingNavigation = nil
    timeline.navigate(to: intent, motion: animation.motion, direction: direction, at: time)
    presentationChanged()
  }

  /// Convert a row placement into a reading anchor against the target viewport.
  private func intent(for request: ChatListScrollRequest<ID>, height: CGFloat?) -> TimelineIntent<ID>? {
    guard let height else { return nil }
    let reading = viewport.readingHeight
    func top(_ offset: CGFloat) -> TimelineIntent<ID> {
      .reading(.init(id: request.id, localY: 0, viewportY: offset, edge: .top))
    }
    func bottom(_ offset: CGFloat) -> TimelineIntent<ID> {
      .reading(.init(id: request.id, localY: height, viewportY: offset, edge: .bottom))
    }
    switch request.position {
      case let .top(offset): return top(offset)
      case let .bottom(offset): return bottom(offset)
      case .center: return height <= reading ? top((reading - height) / 2) : top(0)
      case .visible:
        let layout = timeline.layout
        guard let placement = layout.placement(for: request.id), !placement.isExiting else {
          return height <= reading ? top((reading - height) / 2) : top(0)
        }
        let rowTop = placement.flowFrame.minY - layout.readingRect.minY
        if rowTop >= 0, rowTop + height <= layout.viewport.readingHeight { return top(rowTop) }
        if rowTop < 0 || height > reading { return top(0) }
        return bottom(0)
    }
  }

  public func beginUserScroll(at origin: CGFloat) {
    guard !isDisposed, isActive, origin.isFinite, !timeline.isReordering else { return }
    inputGeneration &+= 1
    let began = !isUserScrolling
    isUserScrolling = true
    pendingNavigation = nil
    lastScrollActivity = now()
    // A user gesture revokes any deferred explicit navigation, but allows
    // compatible content to finish preparing under the current reading intent.
    if let pending {
      self.pending = .init(snapshot: pending.snapshot, intent: nil, animation: pending.animation,
                           transitions: pending.transitions, direction: nil)
    }
    timeline.beginUserScroll(at: origin)
    overscrolling = origin < -0.01 || origin > timeline.layout.maximumOrigin + 0.01
    if began { onScrollEvent?(.userScrollBegan) }
  }

  public func userScrolled(to origin: CGFloat) {
    guard !isDisposed, isActive, origin.isFinite, !timeline.isReordering else { return }
    let previous = timeline.layout.originY
    timeline.userScrolled(to: origin)
    lastScrollActivity = now()
    overscrolling = origin < -0.01 || origin > timeline.layout.maximumOrigin + 0.01
    let delta = origin - previous
    if abs(delta) > 0.5 {
      let direction: ChatListScrollDirection = delta > 0 ? .down : .up
      if direction != lastDirection {
        lastDirection = direction
        onScrollEvent?(.directionChanged(direction))
      }
    }
    presentationChanged()
  }

  public func endUserScroll(at origin: CGFloat, time: Double? = nil) {
    guard !isDisposed, isActive, origin.isFinite, !timeline.isReordering else { return }
    overscrolling = origin < -0.01 || origin > timeline.layout.maximumOrigin + 0.01
    guard !overscrolling else { return }
    let ended = isUserScrolling
    isUserScrolling = false
    lastScrollActivity = now()
    timeline.endUserScroll(at: origin, canFollowLatest: snapshot?.history.isAtLiveEnd == true)
    if ended { onScrollEvent?(.userScrollEnded) }
    finishDeferred(at: time ?? now())
  }

  /// Hosts report the end of a drag gesture; deceleration may continue.
  public func notifyDraggingEnded(willDecelerate: Bool) {
    guard !isDisposed, isActive else { return }
    onScrollEvent?(.draggingEnded(willDecelerate: willDecelerate))
    // Telegram reports a pull past 48 pt, e.g. to open the next unread chat.
    let layout = timeline.layout
    if layout.originY < -48 { onScrollEvent?(.releasedPastEdge(.older)) }
    else if layout.originY > layout.maximumOrigin + 48 { onScrollEvent?(.releasedPastEdge(.newer)) }
  }

  private func finishDeferred(at time: Double) {
    guard isActive, !timeline.isReordering else { return }
    // Only the final compound state is observable by the native host.
    deferringPresentation = true
    defer {
      deferringPresentation = false
      presentationChanged()
    }
    timeline.synchronizeClock(at: time)
    if let pending {
      self.pending = nil
      do {
        _ = try install(pending.snapshot, intent: pending.intent, animation: pending.animation, at: time,
                        transitions: pending.transitions, direction: pending.direction)
      } catch { onPreparationError?(error) }
    } else {
      var next = viewport
      if let snapshot { next.width = snapshot.context.width }
      if next != timeline.targetViewport { timeline.resize(viewport: next, motion: nil, at: time) }
      presentationChanged()
    }
    if let navigation = pendingNavigation {
      pendingNavigation = nil
      timeline.navigate(to: navigation.intent, motion: navigation.animation.motion,
                        direction: navigation.direction, at: time)
      presentationChanged()
    }
  }

  public func advance(to time: Double) {
    guard !isDisposed, isActive else { return }
    if overscrolling {
      guard timeline.advanceViewportDuringOverscroll(to: time) else { return }
    } else { timeline.advance(to: time) }
    advanceIdleDecorations(to: time)
    retiring = retiring.filter { timeline.layout.placement(for: $0.key)?.isExiting == true }
    presentationChanged()
  }

  @discardableResult
  public func refineAnchor(
    row: ID, location: ChatListAnchorLocation, viewportY: CGFloat, edge: TimelineAnchorEdge = .top
  ) -> Bool {
    guard !isUserScrolling, !overscrolling,
          let placement = timeline.layout.placement(for: row),
          let localY = location.localY(in: placement.row.elements) else { return false }
    return timeline.refineReadingAnchor(.init(id: row, localY: localY, viewportY: viewportY, edge: edge))
  }

  // MARK: Reordering

  /// Lift the row at `touchY` (viewport coordinates). Hosts call this from a
  /// long press; `canReorder` decides which rows may move.
  @discardableResult
  public func beginReorder(id: ID, touchY: CGFloat, at time: Double) -> Bool {
    guard !isDisposed, isActive, !isUserScrolling, !overscrolling, let canReorder else { return false }
    pendingNavigation = nil
    guard timeline.beginReorder(id: id, touchY: touchY, at: time, canMove: canReorder) else { return false }
    seenReorderHops = timeline.reorderHops
    presentationChanged()
    return true
  }

  public func updateReorder(touchY: CGFloat, at time: Double) {
    guard !isDisposed, isActive, timeline.isReordering else { return }
    timeline.updateReorder(touchY: touchY, at: time)
    presentationChanged()
  }

  /// Drop the lifted row. The app should publish the new order; the next
  /// snapshot animates any rows that still move.
  @discardableResult
  public func endReorder(at time: Double) -> ChatListReorder<ID>? {
    guard !isDisposed, timeline.isReordering else { return nil }
    let result = timeline.endReorder(at: time)
    animatesMovesOnNextApply = true
    presentationChanged()
    if let result, result.fromIndex != result.toIndex { onReorder?(result) }
    if isActive, !isUserScrolling, !overscrolling { finishDeferred(at: time) }
    return result
  }

  public func cancelReorder(at time: Double) {
    guard !isDisposed, timeline.isReordering else { return }
    timeline.cancelReorder(at: time)
    presentationChanged()
    if isActive, !isUserScrolling, !overscrolling { finishDeferred(at: time) }
  }

  // MARK: Frame events

  private func publishFrameEvents() {
    let layout = timeline.layout
    if timeline.navigationCompletions != seenNavigationCompletions {
      seenNavigationCompletions = timeline.navigationCompletions
      lastScrollActivity = now()
      onScrollEvent?(.navigationFinished)
    }
    if timeline.reorderHops != seenReorderHops {
      seenReorderHops = timeline.reorderHops
      if let id = layout.reorderingID { onReorderHop?(id) }
    }
    if let onContentOffsetChanged {
      var delta: CGFloat = 0
      if let reference = lastReference, let frame = layout.viewportFrame(for: reference.id) {
        delta = frame.minY - reference.y
      }
      let range = layout.flowRows(in: layout.readingRect)
      if let row = layout.rows[range].first(where: { !$0.isExiting && !$0.isReordering }) {
        lastReference = (row.row.id, row.frame.minY - layout.originY)
      } else {
        lastReference = nil
      }
      let offset = ChatListContentOffset(
        fromTop: layout.originY, fromBottom: layout.maximumOrigin - layout.originY, delta: delta
      )
      let moved = offset.fromTop != lastContentOffset?.fromTop || offset.fromBottom != lastContentOffset?.fromBottom
      if moved || delta != 0 {
        lastContentOffset = offset
        onContentOffsetChanged(offset)
      }
    }
    if let onVisibleRangeChanged {
      let range = layout.visibleRange
      if range != lastVisibleRange {
        lastVisibleRange = range
        onVisibleRangeChanged(range)
      }
    }
  }

  // MARK: Idle decorations

  private var awaitsIdleDeadline: Bool {
    guard let snapshot, snapshot.decorations.contains(where: \.hidesWhenIdle) else { return false }
    return isUserScrolling || now() - lastScrollActivity < decorationIdleDelay
  }

  private func advanceIdleDecorations(to time: Double) {
    guard let snapshot else { return }
    let dt = max(0, time - (idleClock ?? time))
    idleClock = time
    let idle = !isUserScrolling && time - lastScrollActivity >= decorationIdleDelay
    var live = Set<String>()
    for decoration in snapshot.decorations where decoration.hidesWhenIdle {
      live.insert(decoration.id)
      let stuck = decoration.placement(in: timeline.layout)?.isStuck ?? false
      var opacity = idleOpacities[decoration.id] ?? TimelineSpring(1)
      let target: CGFloat = stuck && idle ? 0 : 1
      // Telegram: 0.3 s back in, 0.4 s out.
      if opacity.target != target {
        opacity.set(target, motion: .timed(duration: target == 1 ? 0.3 : 0.4, curve: .easeInOut))
      } else {
        opacity.advance(dt)
      }
      idleOpacities[decoration.id] = opacity
    }
    idleOpacities = idleOpacities.filter { live.contains($0.key) }
  }

  /// Hosts call after native frames and reached clip origin have been installed.
  public func didPresent() {
    guard !isDisposed, isActive, let snapshot else { return }
    let presentedHost = hostOwner
    let presentedGeneration = generation
    let presentedInput = inputGeneration
    onPresentation?(.init(generation: generation, layout: timeline.layout, intent: timeline.intent,
                          isUserScrolling: isUserScrolling))
    guard !isDisposed, isActive, hostOwner === presentedHost,
          generation == presentedGeneration, inputGeneration == presentedInput else { return }
    let layout = timeline.layout
    let older = layout.originY <= historyTriggerDistance
    let newer = layout.maximumOrigin - layout.originY <= historyTriggerDistance
    if !older { demandedOlder = false }
    if !newer { demandedNewer = false }
    if older, snapshot.history.hasOlder, !demandedOlder, staging?.older != true {
      demandedOlder = true
      onHistoryDemand?(.older)
    }
    guard !isDisposed, isActive, hostOwner === presentedHost,
          generation == presentedGeneration, inputGeneration == presentedInput else { return }
    if newer, snapshot.history.hasNewer, !demandedNewer, staging?.newer != true {
      demandedNewer = true
      onHistoryDemand?(.newer)
    }
  }

  /// Re-arm after a page made coverage/cursor progress without adding a row,
  /// or after an explicit retry. Call before publishing the resulting snapshot.
  /// A stream of unchanged row boundaries alone never restarts a page request.
  public func rearmHistoryDemand(at edge: ChatListEdge) {
    switch edge {
      case .older: demandedOlder = false
      case .newer: demandedNewer = false
    }
  }

  public func setActive(_ active: Bool, at time: Double) {
    guard !isDisposed, isActive != active else { return }
    isActive = active
    // Activation controls actual native scheduling even while mounted. Resume
    // notifies after deferred state has been reconciled on the frozen clock.
    defer { if hostOwner != nil { hostPresentationChanged?() } }
    timeline.synchronizeClock(at: time)
    if active {
      let needsRefresh = needsSnapshotOnActivation
      overscrolling = false
      finishDeferred(at: time)
      if (needsRefresh || snapshot?.context != layoutContext), layoutContext.width > 0 {
        needsSnapshotOnActivation = false
        onNeedsSnapshot?(layoutContext)
      }
    } else {
      needsSnapshotOnActivation = needsSnapshotOnActivation || preparations.active != nil
      cancelPreparation()
      if timeline.isReordering { timeline.cancelReorder(at: time) }
      if isUserScrolling {
        timeline.endUserScroll(at: timeline.layout.originY, canFollowLatest: timeline.intent == .latest)
      }
      isUserScrolling = false
      overscrolling = false
    }
  }

  public func dispose() {
    guard !isDisposed else { return }
    isDisposed = true
    if hostOwner != nil { hostPresentationChanged?() }
    cancelPreparation()
    pending = nil
    pendingNavigation = nil
    hostOwner = nil
    hostWillApply = nil
    hostPresentationChanged = nil
    hostWillRemove = nil
    snapshot = nil
    installed.removeAll()
    retiring.removeAll()
    timeline = .init(viewport: viewport)
    onWillApply = nil
    onPresentationChanged = nil
    onPresentation = nil
    onHistoryDemand = nil
    onNeedsSnapshot = nil
    onPreparationError = nil
    onScrollEvent = nil
    onContentOffsetChanged = nil
    onVisibleRangeChanged = nil
    onWillRemove = nil
    onReorder = nil
    onReorderHop = nil
    canReorder = nil
  }
}
