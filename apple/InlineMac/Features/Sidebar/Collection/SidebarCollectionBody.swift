import AppKit
import InlineKit
import InlineMacSidebarModel
import InlineMacUI
import Logger
import OSLog
import Observation
import QuartzCore
import SwiftUI

/// Collection-backed body shared by the production Inbox and All Chats modes.
///
/// `NSCollectionView` supplies reuse and scrolling. Internal reorder deliberately
/// does not use `NSDraggingSession`, collection-view drop proposals, or native
/// drag imagery. One app-owned drag state drives the lifted preview and layout
/// slot so they cannot disagree.
struct SidebarCollectionBody: NSViewControllerRepresentable {
  let rows: [SidebarCollectionRow]
  let tree: SidebarCollectionTree
  let isContentReady: Bool
  let reorderPolicy: SidebarCollectionReorderPolicy
  let scrollRequest: SidebarCollectionScrollRequest?
  let renderState: SidebarCollectionRenderState
  let renderer: SidebarCollectionRowRenderer
  let content: (
    SidebarCollectionRow,
    SidebarCollectionRowRenderContext,
    SidebarCollectionRowHostState
  ) -> AnyView
  let nativeContent: (
    SidebarCollectionRow,
    SidebarCollectionRowRenderContext
  ) -> SidebarNativeRowConfiguration
  let dragPreviewContent: (SidebarCollectionRow) -> AnyView
  let actions: SidebarCollectionActions

  func makeNSViewController(context _: Context) -> SidebarCollectionBodyController {
    let controller = SidebarCollectionBodyController()
    controller.update(
      input: SidebarCollectionBodyInput(
        rows: rows,
        tree: tree,
        isContentReady: isContentReady,
        reorderPolicy: reorderPolicy,
        renderState: renderState,
        renderer: renderer
      ),
      scrollRequest: scrollRequest,
      content: content,
      nativeContent: nativeContent,
      dragPreviewContent: dragPreviewContent,
      actions: actions
    )
    return controller
  }

  func updateNSViewController(_ controller: SidebarCollectionBodyController, context _: Context) {
    controller.update(
      input: SidebarCollectionBodyInput(
        rows: rows,
        tree: tree,
        isContentReady: isContentReady,
        reorderPolicy: reorderPolicy,
        renderState: renderState,
        renderer: renderer
      ),
      scrollRequest: scrollRequest,
      content: content,
      nativeContent: nativeContent,
      dragPreviewContent: dragPreviewContent,
      actions: actions
    )
  }

  static func dismantleNSViewController(
    _ controller: SidebarCollectionBodyController,
    coordinator _: Void
  ) {
    controller.prepareForRemoval()
  }
}

private struct SidebarCollectionUnreadButtonHost: View {
  let model: SidebarCollectionUnreadButtonModel
  let direction: SidebarUnreadBelowButton.Direction
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  var body: some View {
    ZStack {
      if let state = model.state {
        SidebarUnreadBelowButton(
          count: state.count,
          direction: direction,
          action: action
        )
        .transition(
          accessibilityReduceMotion
            ? .opacity
            : SidebarUnreadBelowButton.transition(for: direction)
        )
      }
    }
    // NSHostingView follows this view's intrinsic size. Without a stable frame,
    // removing the only child collapses the host while its transition is still
    // rendering, shifting the departing button diagonally toward the constraint.
    .frame(
      width: SidebarUnreadBelowButton.hostLayoutSize.width,
      height: SidebarUnreadBelowButton.hostLayoutSize.height
    )
    .animation(
      accessibilityReduceMotion
        ? .easeOut(duration: 0.12)
        : SidebarUnreadBelowButton.visibilityAnimation,
      value: model.state
    )
  }
}

@MainActor
@Observable
private final class SidebarCollectionUnreadButtonModel {
  var state: SidebarUnreadViewportDirection<SidebarCollectionNodeID>?
}

private struct SidebarCollectionBodyInput {
  let rows: [SidebarCollectionRow]
  let tree: SidebarCollectionTree
  let isContentReady: Bool
  let reorderPolicy: SidebarCollectionReorderPolicy
  let renderState: SidebarCollectionRenderState
  let renderer: SidebarCollectionRowRenderer
}

@MainActor
private final class SidebarCollectionRootView: NSView {
  var liveResizeDidStart: (() -> Void)?
  var liveResizeDidEnd: (() -> Void)?

  override func viewWillStartLiveResize() {
    super.viewWillStartLiveResize()
    liveResizeDidStart?()
  }

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    liveResizeDidEnd?()
  }
}

@MainActor
final class SidebarCollectionBodyController: NSViewController {
  private enum Section {
    case main
  }

  private typealias ModelSlot = SidebarCollectionSlot<
    SidebarCollectionNodeID,
    SidebarOrderLane?
  >
  private typealias OptimisticState = SidebarCollectionOptimisticState<
    SidebarCollectionNodeID,
    SidebarOrderLane?
  >

  private struct Proposal: Equatable {
    /// AppKit geometry attached to a model-owned semantic slot. Slot legality
    /// and mutation remain in `InlineMacSidebarModel`.
    let slot: ModelSlot
    let destinationIndex: Int
    let targetLane: SidebarOrderLane
    let guideY: CGFloat
  }

  private struct ProposalLayoutMode: Hashable {
    let revealsEmptyPinnedSection: Bool
    let hidesPinnedHeader: Bool
  }

  private enum DragPreviewMotion {
    case railed
    case freeform
  }

  private struct ProposalGroup {
    let proposals: [Proposal]
    let positions: [Double]
    let indexBySlot: [ModelSlot: Int]

    init(_ proposals: [Proposal] = []) {
      self.proposals = proposals.enumerated().sorted { lhs, rhs in
        if lhs.element.guideY != rhs.element.guideY {
          return lhs.element.guideY < rhs.element.guideY
        }
        return lhs.offset < rhs.offset
      }.map(\.element)
      positions = self.proposals.map { Double($0.guideY) }
      indexBySlot = Dictionary(
        self.proposals.enumerated().map { ($0.element.slot, $0.offset) },
        uniquingKeysWith: { first, _ in first }
      )
    }

    var isEmpty: Bool { proposals.isEmpty }
  }

  private struct ProjectedHitGuide {
    let nodeID: SidebarCollectionNodeID
    let parentID: SidebarCollectionNodeID?
    let isContainer: Bool
    let minY: CGFloat
    let middleY: CGFloat
    let maxY: CGFloat
  }

  private struct ProjectedRootGuide {
    let rowID: SidebarCollectionRow.ID
    let nodeID: SidebarCollectionNodeID
    let orderLane: SidebarOrderLane
  }

  private enum ReorderSource {
    case chat(SidebarProjectedItem)
    case folder(SidebarProjectedFolder)

    init?(_ row: SidebarCollectionRow) {
      switch row.kind {
      case let .chat(item): self = .chat(item)
      case let .folder(folder): self = .folder(folder)
      default: return nil
      }
    }

    var nodeID: SidebarCollectionNodeID {
      switch self {
      case let .chat(item): item.nodeID
      case let .folder(folder): folder.nodeID
      }
    }

    var rowID: SidebarCollectionRow.ID {
      switch self {
      case let .chat(item): .chat(item.id)
      case let .folder(folder): .folder(folder.id)
      }
    }

    var orderLane: SidebarOrderLane? {
      switch self {
      case let .chat(item): item.orderLane
      case let .folder(folder): folder.lane
      }
    }

    var lane: SidebarOrderLane? {
      switch self {
      case let .chat(item): item.lane
      case let .folder(folder): folder.lane
      }
    }

    var parentID: SidebarCollectionNodeID? {
      guard case let .chat(item) = self else { return nil }
      return item.parentID
    }

    var chat: SidebarProjectedItem? {
      guard case let .chat(item) = self else { return nil }
      return item
    }

    var isExpandable: Bool {
      switch self {
      case let .chat(item): item.isExpandable
      case .folder: true
      }
    }

    var isExpanded: Bool {
      switch self {
      case let .chat(item): item.isExpanded
      case let .folder(folder): folder.isExpanded
      }
    }

    func supports(_ policy: SidebarCollectionReorderPolicy) -> Bool {
      switch self {
      case .chat: true
      case .folder:
        policy.allowsFolderMove(changesSection: true, reordersStableNormalLane: false)
      }
    }
  }

  private struct ReducedRows {
    let ids: [SidebarCollectionRow.ID]
    let indexByID: [SidebarCollectionRow.ID: Int]

    init(removing removedIDs: Set<SidebarCollectionRow.ID>, from rowIDs: [SidebarCollectionRow.ID]) {
      ids = rowIDs.filter { removedIDs.contains($0) == false }
      indexByID = Dictionary(
        uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) }
      )
    }
  }

  private struct ReorderSession {
    let id: UUID
    let source: ReorderSource
    let tree: SidebarCollectionTree
    let dragGroup: SidebarCollectionDragGroup<SidebarCollectionNodeID>
    let legalSlots: Set<ModelSlot>
    let originalRows: [SidebarCollectionRow]
    let originalRowIDs: [SidebarCollectionRow.ID]
    let rowByID: [SidebarCollectionRow.ID: SidebarCollectionRow]
    let indexByRowID: [SidebarCollectionRow.ID: Int]
    let draggedBlockIDs: [SidebarCollectionRow.ID]
    let stableFrames: [SidebarCollectionRow.ID: CGRect]
    let startScreenPoint: CGPoint
    let initialPreviewFrame: CGRect
    let grabOffsetY: CGFloat
    var pointerScreenPoint: CGPoint
    var pointerInCollection: CGPoint
    var rootProposals = ProposalGroup()
    var pinnedRootProposals = ProposalGroup()
    var normalRootProposals = ProposalGroup()
    var childProposals = ProposalGroup()
    var rawRootProposals: [Proposal] = []
    var rawChildProposals: [Proposal] = []
    let projectedHitGuides: [ProjectedHitGuide]
    let projectedVerticalHitGuides: [SidebarCollectionVerticalHitGuide]
    var pinBoundaryY: CGFloat?
    let emptyPinnedRevealThresholdY: CGFloat?
    let canRevealEmptyPinnedSection: Bool
    var showsEmptyPinnedSection = false
    var pinDropInstructionIsDimmed = false
    let reorderPolicy: SidebarCollectionReorderPolicy
    var originalProposal: Proposal?
    var proposal: Proposal?
    var isSettling = false
  }

  private struct PendingMove {
    /// UI metadata paired with the model's optimistic move intent.
    let id: UUID
    let sourceID: SidebarCollectionRow.ID
    let sourceIDs: Set<SidebarCollectionRow.ID>
    let targetLane: SidebarOrderLane
  }

  private struct LocalSettle {
    let id: UUID
    var sourceIDs: Set<SidebarCollectionRow.ID>
    let keepsEmptyPinnedSection: Bool
    var previewFinished = false
    var presentationFinished = false
  }

  private struct VisiblePresentation {
    let modelFrame: CGRect
    let translationY: CGFloat
    let opacity: Float
  }

  private struct ViewportAnchor {
    let rowID: SidebarCollectionRow.ID
    let offsetFromViewportTop: CGFloat
  }

  private struct ActiveDisclosureTransition {
    enum Phase: Equatable {
      case stagingExpansion
      case animating
      case committingCollapse
    }

    let owner: SidebarCollectionDisclosureDescriptor.Owner
    let identity: SidebarCollectionDisclosurePlan<SidebarCollectionRow.ID>
    let geometry: SidebarCollectionDisclosureGeometry
    var expandedPresentation: SidebarBodyPresentation
    var collapsedPresentation: SidebarBodyPresentation
    var targetProgress: CGFloat
    var animationToken: UUID
    var completions: [() -> Void]
    let viewportAnchor: ViewportAnchor?
    var phase: Phase

    var targetPresentation: SidebarBodyPresentation {
      targetProgress > 0.5 ? expandedPresentation : collapsedPresentation
    }
  }

  private enum VisibleRefreshScope {
    case none
    case rowIDs(Set<SidebarCollectionRow.ID>)
    case all
  }

  private let itemIdentifier = NSUserInterfaceItemIdentifier("SidebarCollectionBodyItem")
  private let scrollView = NSScrollView()
  private let collectionView = SidebarExternalDropCollectionView()
  private let layout = SidebarCollectionBodyLayout()
  private let disclosureAnimator = SidebarCollectionDisclosureAnimator()
  private let previewPanel = SidebarDragPreviewPanel()
  private let topScrollEdgeView = NSView()
  private let bottomScrollEdgeView = NSView()
  private let unreadAboveButtonModel = SidebarCollectionUnreadButtonModel()
  private let unreadBelowButtonModel = SidebarCollectionUnreadButtonModel()
  private let log = Log.scoped("SidebarCollectionBody")
  private static let diagnostics = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "chat.inline.InlineMac",
    category: "SidebarFirstFrame"
  )
  private static let signposts = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "chat.inline.InlineMac",
    category: "SidebarFirstFrame"
  )

  private var dataSource: NSCollectionViewDiffableDataSource<Section, SidebarCollectionRow.ID>?
  private var externalRows: [SidebarCollectionRow] = []
  private var externalTree: SidebarCollectionTree?
  private var presentation: SidebarBodyPresentation?
  private var transitionRowByID: [SidebarCollectionRow.ID: SidebarCollectionRow] = [:]
  private var configuredLayoutDrag: SidebarBodyLayoutDrag?
  private var configuredEmptyPinned: SidebarCollectionEmptyPinnedLayoutState?
  private var configuredLayoutDisclosure: SidebarBodyLayoutDisclosure?
  private var configuredSettlingSourceIDs: Set<SidebarCollectionRow.ID> = []
  private var reorderPolicy = SidebarCollectionReorderPolicy.manual
  private var latestRenderState: SidebarCollectionRenderState?
  private var nextPresentationGeneration = 0
  private var hasCompletedViewLayout = false
  private var hasAppliedInitialSnapshot = false
  private var snapshotApplyInFlight = false
  private var snapshotApplyOwnsAnimations = false
  private var isCompletingDisplayUpdate = false
  private var inFlightGeneration: Int?
  private var inFlightViewportAnchor: ViewportAnchor?
  private var inFlightCompletions: [() -> Void] = []
  private var inFlightRefreshScope = VisibleRefreshScope.none
  private var inFlightRequiresSettledReload = false
  private var pendingDisplayUpdate: SidebarBodyDisplayUpdate?
  private var disclosureTransition: ActiveDisclosureTransition?
  private var modeTransitionAnimationTask: Task<Void, Never>?
  private var suppressesModeTransitionAnimations = false
  private var isLiveResizingSidebar = false
  private var isSidebarLiveResizeActive: Bool {
    isLiveResizingSidebar || (isViewLoaded && view.inLiveResize)
  }
  private var content: ((
    SidebarCollectionRow,
    SidebarCollectionRowRenderContext,
    SidebarCollectionRowHostState
  ) -> AnyView)?
  private var nativeContent: ((
    SidebarCollectionRow,
    SidebarCollectionRowRenderContext
  ) -> SidebarNativeRowConfiguration)?
  private var renderer = SidebarCollectionRowRenderer.swiftUI
  private var dragPreviewContent: ((SidebarCollectionRow) -> AnyView)?
  private var actions: SidebarCollectionActions?
  private var reorderSession: ReorderSession?
  private var pendingMoves: [PendingMove] = []
  private var optimisticState: OptimisticState?
  private var pendingMoveObservationTasks: [UUID: Task<Void, Never>] = [:]
  private var localSettle: LocalSettle?
  private var currentScrollRequest: SidebarCollectionScrollRequest?
  private var lastScrollRequestToken: Int?
  private var lastUnreadViewportState: SidebarUnreadViewportResolution<
    SidebarCollectionNodeID
  >?
  private var unreadViewportEntries: [
    SidebarUnreadViewportEntry<SidebarCollectionNodeID>
  ]?
  private var boundsObserver: NSObjectProtocol?
  private var frameObserver: NSObjectProtocol?
  private var lastViewportSize: CGSize?
  private var scrollEdgeVisibility: SidebarScrollEdgeVisibility?
  private var isAwaitingContent = false
  private var firstCompletedAt: TimeInterval?
  private var lastCompletedStructuralIDs: [SidebarCollectionRow.ID]?
  private var scheduledVerificationGeneration: Int?
  private var escapeMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var autoscrollTimer: Timer?
  private var externalDropState = SidebarExternalDropState<
    Int,
    SidebarCollectionExternalDropTarget
  >()
  private let dragPreviewMotion = DragPreviewMotion.railed

  // MARK: - View lifecycle

  override func loadView() {
    let root = SidebarCollectionRootView()
    root.liveResizeDidStart = { [weak self] in
      self?.beginSidebarLiveResize()
    }
    root.liveResizeDidEnd = { [weak self] in
      self?.endSidebarLiveResize()
    }
    collectionView.delegate = self
    layout.minimumLineSpacing = 0
    layout.minimumInteritemSpacing = 0
    layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
    #if DEBUG
    if SidebarCollectionTransitionDiagnostics.usesVanillaFlowLayout {
      let flowLayout = NSCollectionViewFlowLayout()
      flowLayout.minimumLineSpacing = 0
      flowLayout.minimumInteritemSpacing = 0
      flowLayout.sectionInset = NSEdgeInsets(
        top: 0,
        left: Theme.sidebarNativeDefaultEdgeInsets,
        bottom: 20,
        right: Theme.sidebarNativeDefaultEdgeInsets
      )
      collectionView.collectionViewLayout = flowLayout
      os_log(
        .info,
        log: SidebarCollectionTransitionDiagnostics.log,
        "component=collection event=vanilla-flow-control enabled=1"
      )
    } else {
      collectionView.collectionViewLayout = layout
    }
    #else
    collectionView.collectionViewLayout = layout
    #endif
    disclosureAnimator.install(in: collectionView)
    collectionView.backgroundColors = [.clear]
    // Route selection is navigation-owned and each hosted row exposes its own
    // accessibility action and context menu. Mirroring that single selection
    // into NSCollectionView would make row buttons fire through two owners.
    // Add native selection only with an explicit multi-selection product model.
    collectionView.isSelectable = false
    collectionView.register(SidebarCollectionBodyItem.self, forItemWithIdentifier: itemIdentifier)
    collectionView.registerForDraggedTypes(InlinePasteboard.draggedTypes)
    collectionView.draggingUpdatedHandler = { [weak self] sender in
      self?.updateExternalDrop(sender) ?? []
    }
    collectionView.draggingExitedHandler = { [weak self] sender in
      self?.endExternalDrop(sequence: sender?.draggingSequenceNumber)
    }
    collectionView.performDragOperationHandler = { [weak self] sender in
      self?.performExternalDrop(sender) ?? false
    }

    scrollView.drawsBackground = false
    // A legacy scroller consumes document width only after enough rows appear,
    // shifting trailing controls underneath a stationary pointer between a
    // collapsed and expanded section. The sidebar owns stable row geometry;
    // render the modern scroller as an overlay instead of relaying out rows.
    scrollView.scrollerStyle = .overlay
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = collectionView
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.contentView.postsFrameChangedNotifications = true

    collectionView.frame = scrollView.contentView.bounds
    collectionView.autoresizingMask = [.width]
    root.addSubview(scrollView)
    configureScrollEdgeView(topScrollEdgeView)
    configureScrollEdgeView(bottomScrollEdgeView)
    root.addSubview(topScrollEdgeView, positioned: .above, relativeTo: scrollView)
    root.addSubview(bottomScrollEdgeView, positioned: .above, relativeTo: scrollView)
    let unreadAboveHost = makeUnreadButtonHost(
      model: unreadAboveButtonModel,
      direction: .above
    )
    let unreadBelowHost = makeUnreadButtonHost(
      model: unreadBelowButtonModel,
      direction: .below
    )
    root.addSubview(unreadAboveHost, positioned: .above, relativeTo: scrollView)
    root.addSubview(unreadBelowHost, positioned: .above, relativeTo: scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: root.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      unreadAboveHost.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      unreadAboveHost.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
      unreadBelowHost.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      unreadBelowHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
    ])
    view = root

    dataSource = NSCollectionViewDiffableDataSource<Section, SidebarCollectionRow.ID>(
      collectionView: collectionView
    ) { [weak self] collectionView, indexPath, rowID in
      guard let self,
            let row = rowForHosting(rowID),
            let content,
            let item = collectionView.makeItem(
              withIdentifier: itemIdentifier,
              for: indexPath
            ) as? SidebarCollectionBodyItem
      else { return nil }

      item.configure(
        row: row,
        content: { hostState in
          content(row, self.renderContext(for: row), hostState)
        },
        nativeConfiguration: self.renderer == .appKit
          ? self.nativeContent?(row, self.renderContext(for: row))
          : nil,
        isLayoutVisible: isLayoutVisible(at: indexPath),
        preservesCollectionTransition: self.snapshotApplyOwnsAnimations,
        panHandler: { [weak self] rowID, state, location, translation in
          self?.handlePan(
            rowID: rowID,
            state: state,
            location: location,
            translation: translation
          )
        }
      )
      return item
    }

    performPendingDisplayUpdateIfNeeded()

    boundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.viewportBoundsDidChange()
      }
    }
    frameObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.viewportFrameDidChange()
      }
    }
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    prepareForRemoval()
  }

  func prepareForRemoval() {
    modeTransitionAnimationTask?.cancel()
    modeTransitionAnimationTask = nil
    suppressesModeTransitionAnimations = false
    scheduledVerificationGeneration = nil
    isLiveResizingSidebar = false
    stopAutoscroll()
    removeCancellationHooks()
    clearPendingMoves()
    localSettle = nil
    endExternalDrop(sequence: nil)
    reorderSession = nil
    cancelDisclosureTransition()
    if let presentation {
      configureLayout(for: presentation)
      collectionView.needsLayout = true
    }
    finishLocalPresentation()
  }

  deinit {
    if let boundsObserver {
      NotificationCenter.default.removeObserver(boundsObserver)
    }
    if let frameObserver {
      NotificationCenter.default.removeObserver(frameObserver)
    }
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
    }
    if let escapeMonitor {
      NSEvent.removeMonitor(escapeMonitor)
    }
    autoscrollTimer?.invalidate()
    modeTransitionAnimationTask?.cancel()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    synchronizeCollectionWidthWithViewport()
    // SwiftUI may deliver the representable's first update while its AppKit
    // viewport is still zero-sized. Install that first scene only after this
    // layout pass knows the real visible rect, then eagerly materialize every
    // visible item before the window can display a partial collection.
    hasCompletedViewLayout = true
    performPendingDisplayUpdateIfNeeded()
    collectionView.layoutSubtreeIfNeeded()
    collectionView.displayIfNeeded()
    layoutScrollEdgeViews()
    updateScrollEdges(animated: false)
  }

  // MARK: - Viewport geometry

  private func viewportBoundsDidChange() {
    updateUnreadViewportButtons()
    updateScrollEdges(animated: !isSidebarLiveResizeActive)
  }

  private func viewportFrameDidChange() {
    // NavigationSplitView divider drags resize this viewport without putting
    // the window itself in AppKit's `inLiveResize` state. Finish any active
    // row-height transition before applying the new width so the collection
    // never interpolates disclosure geometry while the divider is moving.
    settleDisclosureForGeometryResizeIfNeeded()
    synchronizeCollectionWidthWithViewport()
    // A frame change is part of the same AppKit display transaction. Deferring
    // materialization to the next run-loop turn lets the compositor expose a
    // viewport whose newly visible items do not exist yet.
    collectionView.layoutSubtreeIfNeeded()
    collectionView.displayIfNeeded()
    layoutScrollEdgeViews()
    updateScrollEdges(animated: false)
    updateUnreadViewportButtons(force: true)
    traceViewport(event: "frame")
    schedulePresentationVerification()
  }

  private func configureScrollEdgeView(_ edgeView: NSView) {
    edgeView.wantsLayer = true
    edgeView.layer?.backgroundColor = NSColor.separatorColor
      .withAlphaComponent(0.12)
      .cgColor
    edgeView.alphaValue = 0
  }

  private func layoutScrollEdgeViews() {
    let scale = max(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
    let thickness = 1 / scale
    topScrollEdgeView.frame = CGRect(
      x: 0,
      y: view.bounds.height - thickness,
      width: view.bounds.width,
      height: thickness
    )
    bottomScrollEdgeView.frame = CGRect(
      x: 0,
      y: 0,
      width: view.bounds.width,
      height: thickness
    )
  }

  private func updateScrollEdges(animated: Bool) {
    let viewport = scrollView.contentView.bounds
    let next = SidebarScrollEdgeVisibility.resolve(
      viewportStart: Double(viewport.minY),
      viewportLength: Double(viewport.height),
      // Trailing breathing room is scrollable document padding, not hidden
      // content. It must never light the bottom content-edge separator.
      contentLength: Double(layout.scrollEdgeContentHeight)
    )
    guard scrollEdgeVisibility != next else { return }
    scrollEdgeVisibility = next

    let shouldAnimate = animated
      && !isSidebarLiveResizeActive
      && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = shouldAnimate ? 0.14 : 0
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      topScrollEdgeView.animator().alphaValue = next.top ? 1 : 0
      bottomScrollEdgeView.animator().alphaValue = next.bottom ? 1 : 0
    }
  }

  private func synchronizeCollectionWidthWithViewport() {
    let viewportSize = scrollView.contentView.bounds.size
    guard viewportSize.width > 0, viewportSize.height > 0 else { return }
    let widthChanged = lastViewportSize.map {
      abs($0.width - viewportSize.width) > 0.5
    } ?? true
    let heightChanged = lastViewportSize.map {
      abs($0.height - viewportSize.height) > 0.5
    } ?? true
    guard widthChanged || heightChanged else { return }

    lastViewportSize = viewportSize
    let updates = {
      if widthChanged {
        var documentFrame = self.collectionView.frame
        documentFrame.size.width = viewportSize.width
        self.collectionView.frame = documentFrame
      }
      self.collectionView.collectionViewLayout?.invalidateLayout()
      self.collectionView.needsLayout = true
      self.collectionView.layoutSubtreeIfNeeded()
    }
    // Frame notifications cover both window live-resize and SwiftUI's split
    // divider. Always establish a zero-duration AppKit transaction here; a
    // surrounding SwiftUI animation must not interpolate native row frames.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      context.allowsImplicitAnimation = false
      updates()
    }
  }

  private func beginSidebarLiveResize() {
    guard !isLiveResizingSidebar else { return }
    isLiveResizingSidebar = true
    settleDisclosureForGeometryResizeIfNeeded()
    refreshVisibleContent(.all)
    synchronizeCollectionWidthWithViewport()
    updateScrollEdges(animated: false)
  }

  private func endSidebarLiveResize() {
    guard isLiveResizingSidebar else { return }
    isLiveResizingSidebar = false
    synchronizeCollectionWidthWithViewport()
    collectionView.layoutSubtreeIfNeeded()
    collectionView.displayIfNeeded()
    refreshVisibleContent(.all)
    updateScrollEdges(animated: false)
    updateUnreadViewportButtons(force: true)
  }

  private func settleDisclosureForGeometryResizeIfNeeded() {
    guard let transition = disclosureTransition,
          transition.phase == .animating
    else { return }
    disclosureAnimator.reset()
    if transition.targetProgress > 0.5 {
      finishDisclosureTransition(
        target: transition.expandedPresentation,
        transition: transition
      )
    } else {
      commitCollapsedDisclosureSnapshot()
    }
  }

  // MARK: - SwiftUI input and diffable presentation

  fileprivate func update(
    input: SidebarCollectionBodyInput,
    scrollRequest: SidebarCollectionScrollRequest?,
    content: @escaping (
      SidebarCollectionRow,
      SidebarCollectionRowRenderContext,
      SidebarCollectionRowHostState
    ) -> AnyView,
    nativeContent: @escaping (
      SidebarCollectionRow,
      SidebarCollectionRowRenderContext
    ) -> SidebarNativeRowConfiguration,
    dragPreviewContent: @escaping (SidebarCollectionRow) -> AnyView,
    actions: SidebarCollectionActions
  ) {
    self.content = content
    self.nativeContent = nativeContent
    self.renderer = input.renderer
    self.dragPreviewContent = dragPreviewContent
    self.actions = actions
    currentScrollRequest = scrollRequest

    if input.isContentReady == false {
      if isAwaitingContent == false {
        os_log(
          .info,
          log: Self.diagnostics,
          "component=collection event=hold-loading applied=%{public}d current-rows=%{public}d incoming-rows=%{public}d",
          hasAppliedInitialSnapshot ? 1 : 0,
          presentation?.rows.count ?? 0,
          input.rows.count
        )
      }
      isAwaitingContent = true
      if reorderSession != nil {
        cancelReorder(animated: false, reason: "model-loading")
      }
      return
    }

    let resumedFromLoading = isAwaitingContent
    isAwaitingContent = false
    let inputRows = input.rows
    let rows = rowsWithLatentEmptyPinnedGuide(inputRows)
    let tree = input.tree
    let previousExternalRows = externalRows
    let previousExternalIDs = externalRows.map(\.id)
    let disclosureChanged = sectionDisclosureChanged(
      from: previousExternalRows,
      to: inputRows
    )
    let sidebarModeChanged = latestRenderState.map {
      $0.sidebarAsInbox != input.renderState.sidebarAsInbox
    } ?? false
    if sidebarModeChanged {
      suppressesModeTransitionAnimations = true
    }
    if suppressesModeTransitionAnimations {
      extendModeTransitionAnimationSuppression()
    }
    externalRows = inputRows
    externalTree = tree
    let reorderPolicyChanged = reorderPolicy != input.reorderPolicy
    reorderPolicy = input.reorderPolicy
    latestRenderState = input.renderState
    if reorderPolicyChanged, reorderSession != nil {
      cancelReorder(animated: false, reason: "policy-update")
      handleScrollRequestIfPossible()
      return
    }

    if let session = reorderSession {
      // A drag is one frozen collection scene. Keep accepting current content,
      // actions, and external model references, but never rehost rows, mutate
      // collection identity, or reconfigure geometry under the recognizer.
      // Membership changes invalidate the preview's frozen group; unrelated
      // order/content changes are rebased once the gesture ends.
      let sourceNodeID = session.source.nodeID
      let latestGroup = try? tree.snapshot.dragGroup(for: sourceNodeID)
      let sourceParentChanged = tree.snapshot.parentID(of: sourceNodeID)
        != session.tree.snapshot.parentID(of: sourceNodeID)
      let sourceSectionChanged = tree.snapshot.sectionID(containing: sourceNodeID)
        != session.tree.snapshot.sectionID(containing: sourceNodeID)
      if latestGroup != session.dragGroup || sourceParentChanged || sourceSectionChanged {
        cancelReorder(animated: false, reason: "drag-group-update")
        handleScrollRequestIfPossible()
      }
      return
    }

    let reconciliation = reconcileOptimisticState(with: tree.snapshot)
    if pendingMoves.isEmpty == false, let optimisticState {
      let rebasedRows = presentationRows(
        snapshot: optimisticState.presented,
        tree: tree,
        basedOn: rows,
        pendingMoves: pendingMoves
      )
      requestDisplayRows(
        rebasedRows,
        animatingDifferences: resumedFromLoading == false
          && suppressesModeTransitionAnimations == false
          && (previousExternalIDs != inputRows.map(\.id)
            || reconciliation?.cancelledMoveIDs.isEmpty == false),
        reason: resumedFromLoading
          ? "model-ready"
          : (sidebarModeChanged ? "sidebar-mode-update" : "optimistic-rebase")
      )
    } else {
      optimisticState = OptimisticState(confirmed: tree.snapshot)
      requestDisplayRows(
        rows,
        animatingDifferences: resumedFromLoading == false
          && suppressesModeTransitionAnimations == false
          && (previousExternalIDs != inputRows.map(\.id)
            || reconciliation?.cancelledMoveIDs.isEmpty == false),
        reason: resumedFromLoading
          ? "model-ready"
          : (sidebarModeChanged
            ? "sidebar-mode-update"
            : (disclosureChanged
              ? "section-disclosure"
              : (reconciliation?.acknowledgedMoveIDs.isEmpty == false
                ? "optimistic-acknowledged"
                : "model-update")))
      )
    }

    handleScrollRequestIfPossible()
  }

  /// Keep a semantic reason for diagnostics while routing section disclosure
  /// through the same ordinary row-diff path as reply-thread disclosure.
  private func sectionDisclosureChanged(
    from previousRows: [SidebarCollectionRow],
    to nextRows: [SidebarCollectionRow]
  ) -> Bool {
    SidebarCollectionRow.SectionHeader.allCases.contains { section in
      let previous = previousRows.first { $0.id == .sectionHeader(section) }?
        .sectionHeader?.isExpanded
      let next = nextRows.first { $0.id == .sectionHeader(section) }?
        .sectionHeader?.isExpanded
      guard let previous, let next else { return false }
      return previous != next
    }
  }

  /// Source observation follows the preference update and can publish one or
  /// two snapshots immediately afterward. Keep that entire short handoff out
  /// of diffable's move animation, then restore normal model-update animation
  /// after the mode's presentation has been quiet for one brief interval.
  private func extendModeTransitionAnimationSuppression() {
    modeTransitionAnimationTask?.cancel()
    modeTransitionAnimationTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(150))
      } catch {
        return
      }
      guard let self else { return }
      suppressesModeTransitionAnimations = false
      modeTransitionAnimationTask = nil
    }
  }

  private var displayRows: [SidebarCollectionRow] {
    presentation?.rows ?? []
  }

  private func rowForHosting(
    _ rowID: SidebarCollectionRow.ID
  ) -> SidebarCollectionRow? {
    presentation?.rowByID[rowID] ?? transitionRowByID[rowID]
  }

  private func requestDisplayRows(
    _ rows: [SidebarCollectionRow],
    animatingDifferences: Bool,
    reason: String,
    completion: (() -> Void)? = nil
  ) {
    guard let latestRenderState else {
      completion?()
      return
    }

    if snapshotApplyInFlight == false,
       isCompletingDisplayUpdate == false,
       pendingDisplayUpdate == nil,
       let presentation,
       presentation.rows == rows,
       presentation.renderState == latestRenderState,
       layoutInteractionConfigurationChanged == false {
      completion?()
      handleScrollRequestIfPossible()
      return
    }

    nextPresentationGeneration += 1
    let nextPresentation = SidebarBodyPresentation(
      generation: nextPresentationGeneration,
      rows: rows,
      renderState: latestRenderState
    )
    let update = SidebarBodyDisplayUpdate(
      presentation: nextPresentation,
      reason: reason,
      animatingDifferences: animatingDifferences,
      completions: completion.map { [$0] } ?? []
    )
    tracePresentation(
      event: "request",
      presentation: nextPresentation,
      reason: reason,
      animated: animatingDifferences
    )

    if disclosureTransition != nil {
      handleDisplayUpdateDuringDisclosure(update)
      return
    }

    guard dataSource != nil else {
      pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: update)
      return
    }

    guard hasAppliedInitialSnapshot || hasUsableInitialViewport else {
      pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: update)
      return
    }

    if isCompletingDisplayUpdate {
      pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: update)
      return
    }

    if snapshotApplyInFlight {
      if nextPresentation.orderedIDs == presentation?.orderedIDs {
        let rendererChanged = presentation.map {
          $0.renderState.preview.renderer != nextPresentation.renderState.preview.renderer
        } ?? false
        if rendererChanged || layoutGeometryChanged(
          from: presentation,
          to: nextPresentation
        ) || layoutInteractionConfigurationChanged {
          // Diffable owns item identity until its completion. Renderer swaps
          // and geometry changes replace reusable subtrees or row frames, so
          // coalesce them for the next atomic scene instead of mutating the
          // collection under an in-flight snapshot.
          pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: update)
        } else {
          applyContentUpdateDuringSnapshot(update)
        }
      } else {
        pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: update)
        log.debug(
          "presentation #\(nextPresentation.generation) queued reason=\(reason) "
            + "rows=\(rows.count)"
        )
        tracePresentation(
          event: "queued",
          presentation: nextPresentation,
          reason: reason,
          animated: animatingDifferences
        )
      }
      return
    }

    performDisplayUpdate(update)
  }

  private func coalescing(
    _ existing: SidebarBodyDisplayUpdate?,
    with latest: SidebarBodyDisplayUpdate
  ) -> SidebarBodyDisplayUpdate {
    var update = latest
    if let existing {
      update.completions = existing.completions + latest.completions
    }
    return update
  }

  private func performDisplayUpdate(_ update: SidebarBodyDisplayUpdate) {
    guard let dataSource else {
      pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: update)
      return
    }

    let next = update.presentation
    if hasAppliedInitialSnapshot,
       update.animatingDifferences,
       !isSidebarLiveResizeActive,
       NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false,
       reorderSession == nil,
       let previous = presentation,
       let descriptor = SidebarCollectionDisclosureDescriptor.make(
         from: previous,
         to: next
       ), case .chat = descriptor.owner {
      // Nested reply groups need the interruptible shared-boundary animator.
      // Section disclosure intentionally stays on the collection view's
      // ordinary row diff so a selected survivor can reflow naturally.
      performDisclosureDisplayUpdate(update, descriptor: descriptor)
      return
    }
    if hasAppliedInitialSnapshot,
       dataSource.snapshot().itemIdentifiers == next.orderedIDs {
      applyContentOnlyUpdate(update)
      return
    }

    let previousPresentation = presentation
    let previousRows = previousPresentation?.rowByID ?? [:]
    let animate = hasAppliedInitialSnapshot
      && update.animatingDifferences
      && !isSidebarLiveResizeActive
      && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    inFlightViewportAnchor = update.reason == "optimistic-drop"
      ? nil
      : captureViewportAnchor(survivingIn: Set(next.orderedIDs))
    #if DEBUG
    traceTransitionScene(
      event: "snapshot-before-layout",
      generation: next.generation,
      reason: update.reason
    )
    #endif
    transitionRowByID = previousRows.merging(next.rowByID) { _, latest in latest }
    var refreshScope = refreshScope(from: previousPresentation, to: next)
    presentation = next
    if update.reason == "section-disclosure" {
      let headerIDs = changedSectionHeaderIDs(
        from: previousPresentation,
        to: next
      )
      // The header survives disclosure. Refresh it while the source layout is
      // still authoritative so its chevron starts with the row transaction,
      // then keep completion from assigning the same SwiftUI host again.
      refreshVisibleContent(.rowIDs(headerIDs))
      refreshScope = removing(headerIDs, from: refreshScope)
    }
    // Configure the destination projection without invalidating the source
    // scene ahead of the diffable transaction. The concrete flow layout owns
    // source/destination caching and invalidates itself as the snapshot applies.
    configureLayout(for: next, invalidatesLayout: false)
    inFlightRefreshScope = refreshScope

    var snapshot = NSDiffableDataSourceSnapshot<Section, SidebarCollectionRow.ID>()
    snapshot.appendSections([.main])
    snapshot.appendItems(next.orderedIDs, toSection: .main)

    snapshotApplyInFlight = true
    snapshotApplyOwnsAnimations = animate
    inFlightGeneration = next.generation
    inFlightCompletions.append(contentsOf: update.completions)
    inFlightRequiresSettledReload = hasAppliedInitialSnapshot && animate == false
    disableInteractionForRowsLeavingSnapshot(next.orderedIDs)
    #if DEBUG
    traceTransitionScene(
      event: "snapshot-before-apply",
      generation: next.generation,
      reason: update.reason
    )
    #endif
    log.debug(
      "presentation #\(next.generation) apply reason=\(update.reason) "
        + "rows=\(next.rows.count) animated=\(animate)"
    )
    tracePresentation(
      event: "apply",
      presentation: next,
      reason: update.reason,
      animated: animate
    )
    os_signpost(
      .event,
      log: Self.signposts,
      name: "SidebarPresentationApply",
      "generation=%{public}d rows=%{public}d",
      next.generation,
      next.rows.count
    )

    if hasAppliedInitialSnapshot == false {
      // A first scene is not a diff. Reload semantics avoid asking AppKit to
      // stage appearing items across update callbacks while the window is
      // performing its first display.
      dataSource.apply(snapshot, animatingDifferences: false)
      collectionView.layoutSubtreeIfNeeded()
      collectionView.displayIfNeeded()
      completeDisplayUpdate(generation: next.generation)
    } else if animate, update.reason == "section-disclosure" {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = SidebarDisclosureMotion.duration
        context.timingFunction = CAMediaTimingFunction(
          controlPoints: Float(SidebarDisclosureMotion.controlPoint1.x),
          Float(SidebarDisclosureMotion.controlPoint1.y),
          Float(SidebarDisclosureMotion.controlPoint2.x),
          Float(SidebarDisclosureMotion.controlPoint2.y)
        )
        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
          self?.completeDisplayUpdate(generation: next.generation)
        }
      }
    } else if animate {
      // Close, insertion, and ordinary model updates use AppKit's default
      // collection animation. There is no close-specific snapshot or fade.
      dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
        self?.completeDisplayUpdate(generation: next.generation)
      }
    } else {
      dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        self?.completeDisplayUpdate(generation: next.generation)
      }
    }
  }

  private func performDisclosureDisplayUpdate(
    _ update: SidebarBodyDisplayUpdate,
    descriptor: SidebarCollectionDisclosureDescriptor
  ) {
    guard let dataSource else {
      pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: update)
      return
    }

    let previousPresentation = presentation
    let target = update.presentation
    let liveExpanded = descriptor.liveExpandedPresentation(merging: target)
    let affectedIDs = Set(descriptor.identity.affectedIDs)
    let trailingIDs = Set(descriptor.identity.trailingIDs)
    let requiresExpandedSnapshot = dataSource.snapshot().itemIdentifiers
      != liveExpanded.orderedIDs
    let estimatedHeight = descriptor.identity.affectedIDs.reduce(CGFloat.zero) { height, rowID in
      height + (liveExpanded.rowByID[rowID]?.height ?? 0)
    }
    guard estimatedHeight > 0.5 else {
      performDisplayUpdate(atomicUpdate(from: update))
      return
    }

    let provisionalLayout = SidebarBodyLayoutDisclosure(
      affectedIDs: affectedIDs,
      trailingIDs: trailingIDs,
      collapsedOffsetY: -estimatedHeight,
      hidesAffectedRows: requiresExpandedSnapshot
    )
    let viewportAnchor = captureViewportAnchor(rowID: descriptor.ownerID)
    transitionRowByID = liveExpanded.rowByID
    presentation = liveExpanded
    configureLayout(for: liveExpanded, disclosure: provisionalLayout)

    collectionView.needsLayout = true
    collectionView.layoutSubtreeIfNeeded()

    guard let geometry = disclosureGeometry(
      ownerID: descriptor.ownerID,
      affectedIDs: affectedIDs,
      trailingIDs: trailingIDs,
      expectedHeight: estimatedHeight,
      presentation: liveExpanded
    )
    else {
      configureLayout(for: liveExpanded)
      collectionView.needsLayout = true
      disclosureAnimator.reset()
      performDisplayUpdate(atomicUpdate(from: update))
      return
    }

    var refresh = refreshScope(from: previousPresentation, to: liveExpanded)
    refresh = removing(affectedIDs.union([descriptor.ownerID]), from: refresh)
    refreshVisibleContent(refresh)

    let initialProgress: CGFloat = descriptor.targetProgress > 0.5 ? 0 : 1
    let transition = ActiveDisclosureTransition(
      owner: descriptor.owner,
      identity: descriptor.identity,
      geometry: geometry,
      expandedPresentation: liveExpanded,
      collapsedPresentation: descriptor.collapsedPresentation,
      targetProgress: descriptor.targetProgress,
      animationToken: UUID(),
      completions: update.completions,
      viewportAnchor: viewportAnchor,
      phase: requiresExpandedSnapshot ? .stagingExpansion : .animating
    )
    disclosureTransition = transition

    if requiresExpandedSnapshot {
      var snapshot = NSDiffableDataSourceSnapshot<Section, SidebarCollectionRow.ID>()
      snapshot.appendSections([.main])
      snapshot.appendItems(liveExpanded.orderedIDs, toSection: .main)
      let stagingToken = transition.animationToken
      snapshotApplyInFlight = true
      snapshotApplyOwnsAnimations = false
      dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        self?.continueStagedDisclosure(token: stagingToken)
      }
      tracePresentation(
        event: "disclosure-stage",
        presentation: target,
        reason: update.reason,
        animated: false
      )
      return
    }

    startDisclosureAnimation(initialProgress: initialProgress)
    tracePresentation(
      event: "disclosure-apply",
      presentation: target,
      reason: update.reason,
      animated: true
    )
  }

  private func continueStagedDisclosure(token: UUID) {
    snapshotApplyInFlight = false
    snapshotApplyOwnsAnimations = false
    guard let transition = disclosureTransition,
          transition.phase == .stagingExpansion,
          transition.animationToken == token
    else { return }

    // A structural update that cannot join this disclosure may arrive while
    // diffable is staging the expanded membership. The staging snapshot is
    // now authoritative and AppKit is idle, so settle that scene atomically;
    // `finishDisclosureTransition` will immediately apply the queued update.
    if pendingDisplayUpdate != nil {
      finishDisclosureTransition(
        target: transition.expandedPresentation,
        transition: transition
      )
      return
    }

    guard transition.targetProgress > 0.5 else {
      commitCollapsedDisclosureSnapshot()
      return
    }
    startDisclosureAnimation(initialProgress: 0)
  }

  private func startDisclosureAnimation(initialProgress: CGFloat) {
    guard var transition = disclosureTransition else { return }
    if isSidebarLiveResizeActive {
      disclosureAnimator.reset()
      if transition.targetProgress > 0.5 {
        finishDisclosureTransition(
          target: transition.expandedPresentation,
          transition: transition
        )
      } else {
        commitCollapsedDisclosureSnapshot()
      }
      return
    }
    // Diffable staging can take a frame. Keep the surviving owner on its
    // source state until the body clock is ready, then start its SwiftUI
    // chevron animation in the same display turn as the clipped content.
    refreshVisibleContent(.rowIDs([transition.identity.ownerID]))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    configureLayout(
      for: transition.expandedPresentation,
      disclosure: transition.geometry.layoutState()
    )
    collectionView.needsLayout = true
    collectionView.layoutSubtreeIfNeeded()
    let token = disclosureAnimator.begin(
      geometry: transition.geometry,
      initialProgress: initialProgress,
      targetProgress: transition.targetProgress
    ) { [weak self] token in
      self?.completeDisclosureAnimation(token: token)
    }
    CATransaction.commit()
    transition.phase = .animating
    transition.animationToken = token
    disclosureTransition = transition
  }

  private func handleDisplayUpdateDuringDisclosure(
    _ update: SidebarBodyDisplayUpdate
  ) {
    guard var transition = disclosureTransition,
          let requestedProgress = disclosureProgress(
            owner: transition.owner,
            in: update.presentation
          )
    else {
      abortDisclosureTransition(for: update)
      return
    }

    let expectedIDs = requestedProgress > 0.5
      ? transition.identity.expandedIDs
      : transition.identity.collapsedIDs
    guard update.presentation.orderedIDs == expectedIDs else {
      abortDisclosureTransition(for: update)
      return
    }

    let previousLive = presentation
    if requestedProgress > 0.5 {
      transition.expandedPresentation = update.presentation
    } else {
      transition.collapsedPresentation = update.presentation
    }
    let latestTarget = update.presentation
    let liveExpanded = SidebarBodyPresentation(
      generation: latestTarget.generation,
      rows: transition.expandedPresentation.rows.map {
        latestTarget.rowByID[$0.id] ?? $0
      },
      renderState: latestTarget.renderState
    )
    transition.expandedPresentation = liveExpanded
    transition.completions.append(contentsOf: update.completions)
    let directionChanged = abs(transition.targetProgress - requestedProgress) > 0.001
    transition.targetProgress = requestedProgress
    if transition.phase == .committingCollapse {
      disclosureTransition = transition
      if directionChanged {
        tracePresentation(
          event: "disclosure-reverse-during-commit",
          presentation: update.presentation,
          reason: update.reason,
          animated: false
        )
      }
      return
    }

    // Render the surviving owner's chevron from the requested target while
    // the expanded presentation remains installed solely for transition
    // geometry. This keeps visual state and action semantics in one direction.
    disclosureTransition = transition
    presentation = liveExpanded
    transitionRowByID = liveExpanded.rowByID.merging(
      transition.collapsedPresentation.rowByID
    ) { current, _ in current }
    configureLayout(
      for: liveExpanded,
      disclosure: transition.geometry.layoutState(
        hidesAffectedRows: transition.phase == .stagingExpansion
      )
    )
    collectionView.needsLayout = true
    collectionView.layoutSubtreeIfNeeded()
    refreshVisibleContent(refreshScope(from: previousLive, to: liveExpanded))
    guard directionChanged else { return }
    guard transition.phase == .animating else {
      tracePresentation(
        event: "disclosure-reverse-during-stage",
        presentation: update.presentation,
        reason: update.reason,
        animated: false
      )
      return
    }
    let token = disclosureAnimator.retarget(to: requestedProgress) { [weak self] token in
      self?.completeDisclosureAnimation(token: token)
    }
    disclosureTransition?.animationToken = token
    tracePresentation(
      event: "disclosure-reverse",
      presentation: update.presentation,
      reason: update.reason,
      animated: true
    )
  }

  private func completeDisclosureAnimation(token: UUID) {
    guard let transition = disclosureTransition,
          transition.phase == .animating,
          transition.animationToken == token,
          dataSource != nil
    else { return }

    let target = transition.targetPresentation
    guard transition.targetProgress > 0.5 else {
      commitCollapsedDisclosureSnapshot()
      return
    }
    finishDisclosureTransition(target: target, transition: transition)
  }

  private func commitCollapsedDisclosureSnapshot() {
    guard var transition = disclosureTransition, let dataSource else { return }
    let target = transition.collapsedPresentation
    if dataSource.snapshot().itemIdentifiers == target.orderedIDs {
      finishDisclosureTransition(target: target, transition: transition)
      return
    }

    transition.phase = .committingCollapse
    disclosureTransition = transition
    var snapshot = NSDiffableDataSourceSnapshot<Section, SidebarCollectionRow.ID>()
    snapshot.appendSections([.main])
    snapshot.appendItems(target.orderedIDs, toSection: .main)
    snapshotApplyInFlight = true
    snapshotApplyOwnsAnimations = false
    disableInteractionForRowsLeavingSnapshot(target.orderedIDs)
    dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
      self?.completeCollapsedDisclosureCommit()
    }
  }

  private func completeCollapsedDisclosureCommit() {
    snapshotApplyInFlight = false
    snapshotApplyOwnsAnimations = false
    guard var transition = disclosureTransition,
          transition.phase == .committingCollapse
    else { return }

    // Mixed structural updates are held until diffable has finished owning
    // the collapsed commit. Do not restart the custom clock ahead of a newer
    // queued presentation.
    if pendingDisplayUpdate != nil {
      transition.targetProgress = 0
      finishDisclosureTransition(
        target: transition.collapsedPresentation,
        transition: transition
      )
      return
    }

    guard transition.targetProgress <= 0.5 else {
      let restart = SidebarBodyDisplayUpdate(
        presentation: transition.expandedPresentation,
        reason: "disclosure-restart-after-commit",
        animatingDifferences: true,
        completions: transition.completions
      )
      transition.targetProgress = 0
      transition.completions = []
      pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: restart)
      finishDisclosureTransition(
        target: transition.collapsedPresentation,
        transition: transition
      )
      return
    }
    finishDisclosureTransition(
      target: transition.collapsedPresentation,
      transition: transition
    )
  }

  private func finishDisclosureTransition(
    target: SidebarBodyPresentation,
    transition: ActiveDisclosureTransition
  ) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    disclosureAnimator.reset()
    disclosureTransition = nil
    presentation = target
    transitionRowByID = target.rowByID
    configureLayout(for: target)
    collectionView.needsLayout = true
    collectionView.layoutSubtreeIfNeeded()
    CATransaction.commit()

    reconcileSettledVisibleItems(
      generation: target.generation,
      forceReload: transition.phase == .committingCollapse
    )

    restoreViewportAnchor(transition.viewportAnchor)
    updateScrollEdges(animated: false)
    let completions = transition.completions
    isCompletingDisplayUpdate = true
    completions.forEach { $0() }
    isCompletingDisplayUpdate = false

    let nextUpdate = pendingDisplayUpdate
    pendingDisplayUpdate = nil
    if let nextUpdate {
      performDisplayUpdate(nextUpdate)
    } else {
      validatePresentationInvariants(context: "disclosure-complete")
      updateUnreadViewportButtons(force: true)
      handleScrollRequestIfPossible()
      schedulePresentationVerification(generation: target.generation)
    }
    tracePresentation(
      event: "disclosure-complete",
      presentation: target,
      reason: "settled",
      animated: false
    )
  }

  private func abortDisclosureTransition(for update: SidebarBodyDisplayUpdate) {
    if snapshotApplyInFlight, var transition = disclosureTransition {
      let atomic = SidebarBodyDisplayUpdate(
        presentation: update.presentation,
        reason: "\(update.reason)-after-disclosure-commit",
        animatingDifferences: false,
        completions: transition.completions + update.completions
      )
      transition.completions = []
      disclosureTransition = transition
      pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: atomic)
      return
    }

    let completions = disclosureTransition?.completions ?? []
    cancelDisclosureTransition()
    let atomic = SidebarBodyDisplayUpdate(
      presentation: update.presentation,
      reason: "\(update.reason)-after-disclosure-cancel",
      animatingDifferences: false,
      completions: completions + update.completions
    )
    performDisplayUpdate(atomic)
  }

  private func cancelDisclosureTransition() {
    guard disclosureTransition != nil else {
      disclosureAnimator.reset()
      return
    }
    disclosureAnimator.reset()
    disclosureTransition = nil
    if let presentation {
      configureLayout(for: presentation)
      collectionView.needsLayout = true
      collectionView.layoutSubtreeIfNeeded()
    }
  }

  private func atomicUpdate(
    from update: SidebarBodyDisplayUpdate
  ) -> SidebarBodyDisplayUpdate {
    SidebarBodyDisplayUpdate(
      presentation: update.presentation,
      reason: "\(update.reason)-atomic-fallback",
      animatingDifferences: false,
      completions: update.completions
    )
  }

  private func disclosureProgress(
    owner: SidebarCollectionDisclosureDescriptor.Owner,
    in presentation: SidebarBodyPresentation
  ) -> CGFloat? {
    switch owner {
    case let .section(section):
      guard let isExpanded = presentation.rowByID[.sectionHeader(section)]?
        .sectionHeader?.isExpanded
      else { return nil }
      return isExpanded ? 1 : 0
    case let .chat(id):
      guard let item = presentation.rowByID[.chat(id)]?.projectedItem,
            item.isExpandable
      else { return nil }
      return item.isExpanded ? 1 : 0
    case let .folder(id):
      guard let folder = presentation.rowByID[.folder(id)]?.projectedFolder else { return nil }
      return folder.isExpanded ? 1 : 0
    }
  }

  private func disclosureGeometry(
    ownerID: SidebarCollectionRow.ID,
    affectedIDs: Set<SidebarCollectionRow.ID>,
    trailingIDs: Set<SidebarCollectionRow.ID>,
    expectedHeight: CGFloat,
    presentation: SidebarBodyPresentation
  ) -> SidebarCollectionDisclosureGeometry? {
    guard let ownerIndex = presentation.orderedIDs.firstIndex(of: ownerID),
          let ownerFrame = layout.layoutAttributesForItem(
            at: IndexPath(item: ownerIndex, section: 0)
          )?.frame
    else { return nil }

    var frames: [SidebarCollectionRow.ID: CGRect] = [:]
    for (index, rowID) in presentation.orderedIDs.enumerated() {
      guard affectedIDs.contains(rowID) || trailingIDs.contains(rowID) || rowID == ownerID,
            let frame = layout.layoutAttributesForItem(
              at: IndexPath(item: index, section: 0)
            )?.frame
      else { continue }
      frames[rowID] = frame
    }
    var cursorY = ownerFrame.maxY
    for rowID in presentation.orderedIDs where affectedIDs.contains(rowID) {
      guard let frame = frames[rowID], abs(frame.minY - cursorY) <= 0.75 else {
        return nil
      }
      cursorY = frame.maxY
    }
    let height = cursorY - ownerFrame.maxY
    guard height > 0.5, abs(height - expectedHeight) <= 0.75 else { return nil }
    return SidebarCollectionDisclosureGeometry(
      affectedIDs: affectedIDs,
      trailingIDs: trailingIDs,
      expandedFrames: frames,
      groupTopY: ownerFrame.maxY,
      height: height
    )
  }

  private func visibleItem(
    for rowID: SidebarCollectionRow.ID
  ) -> SidebarCollectionBodyItem? {
    collectionView.visibleItems().compactMap { $0 as? SidebarCollectionBodyItem }
      .first(where: { $0.representedRowID == rowID })
  }

  private func applyContentOnlyUpdate(_ update: SidebarBodyDisplayUpdate) {
    let previousPresentation = presentation
    if unreadViewportInputsChanged(from: previousPresentation, to: update.presentation) {
      unreadViewportEntries = nil
    }
    let geometryChanged = layoutGeometryChanged(
      from: previousPresentation,
      to: update.presentation
    ) || layoutInteractionConfigurationChanged
    let anchor = geometryChanged
      ? captureViewportAnchor(survivingIn: Set(update.presentation.orderedIDs))
      : nil
    presentation = update.presentation
    transitionRowByID = update.presentation.rowByID
    if geometryChanged {
      configureLayout(for: update.presentation)
      collectionView.needsLayout = true
      collectionView.layoutSubtreeIfNeeded()
      restoreViewportAnchor(anchor)
      updateScrollEdges(animated: false)
    }
    refreshVisibleContent(refreshScope(from: previousPresentation, to: update.presentation))
    validatePresentationInvariants(context: "content-update")
    updateUnreadViewportButtons(force: true)
    handleScrollRequestIfPossible()
    update.completions.forEach { $0() }
  }

  private func applyContentUpdateDuringSnapshot(_ update: SidebarBodyDisplayUpdate) {
    if let pendingDisplayUpdate {
      inFlightCompletions.append(contentsOf: pendingDisplayUpdate.completions)
      self.pendingDisplayUpdate = nil
    }
    inFlightCompletions.append(contentsOf: update.completions)
    let previousPresentation = presentation
    if unreadViewportInputsChanged(from: previousPresentation, to: update.presentation) {
      unreadViewportEntries = nil
    }
    presentation = update.presentation
    inFlightRefreshScope = mergeRefreshScopes(
      inFlightRefreshScope,
      refreshScope(from: previousPresentation, to: update.presentation)
    )
    transitionRowByID.merge(update.presentation.rowByID) { _, latest in latest }
    if layoutGeometryChanged(from: previousPresentation, to: update.presentation)
      || layoutInteractionConfigurationChanged {
      configureLayout(for: update.presentation)
      collectionView.needsLayout = true
      collectionView.layoutSubtreeIfNeeded()
      updateScrollEdges(animated: false)
    }
    refreshVisibleContent(refreshScope(from: previousPresentation, to: update.presentation))
    log.debug(
      "presentation #\(update.presentation.generation) refreshed during snapshot "
        + "reason=\(update.reason)"
    )
  }

  private func completeDisplayUpdate(generation: Int) {
    guard inFlightGeneration == generation else {
      assertionFailure("Completed an unexpected sidebar presentation generation")
      return
    }

    #if DEBUG
    traceTransitionScene(
      event: "snapshot-completion-entry",
      generation: generation,
      reason: "completion"
    )
    #endif

    snapshotApplyInFlight = false
    snapshotApplyOwnsAnimations = false
    inFlightGeneration = nil
    hasAppliedInitialSnapshot = true
    let completedPresentation = presentation
    transitionRowByID = presentation?.rowByID ?? [:]
    let refreshScope = inFlightRefreshScope
    inFlightRefreshScope = .none
    // Hosted rows derive both content suppression and accessibility hit
    // testing from layout visibility. Resolve the final scene first so a
    // disclosure cannot refresh its surviving header against transitional
    // hidden attributes and leave that header blank or non-interactive.
    collectionView.layoutSubtreeIfNeeded()
    reconcileSettledVisibleItems(
      generation: generation,
      forceReload: inFlightRequiresSettledReload
    )
    #if DEBUG
    traceTransitionScene(
      event: "snapshot-after-reconcile",
      generation: generation,
      reason: "completion"
    )
    #endif
    inFlightRequiresSettledReload = false
    refreshVisibleContent(refreshScope)
    restoreViewportAnchor(inFlightViewportAnchor)
    inFlightViewportAnchor = nil
    updateScrollEdges(animated: false)

    let completions = inFlightCompletions
    inFlightCompletions.removeAll()
    isCompletingDisplayUpdate = true
    completions.forEach { $0() }
    isCompletingDisplayUpdate = false

    let nextUpdate = pendingDisplayUpdate
    pendingDisplayUpdate = nil
    if let nextUpdate {
      performDisplayUpdate(nextUpdate)
    } else {
      validatePresentationInvariants(context: "snapshot-complete")
      updateUnreadViewportButtons(force: true)
      handleScrollRequestIfPossible()
    }

    log.debug("presentation #\(generation) complete next=\(nextUpdate != nil)")
    if let presentation = completedPresentation {
      let now = ProcessInfo.processInfo.systemUptime
      if firstCompletedAt == nil {
        firstCompletedAt = now
      } else if let firstCompletedAt,
                now - firstCompletedAt < 1,
                let previousIDs = lastCompletedStructuralIDs,
                previousIDs != presentation.orderedIDs {
        os_log(
          .default,
          log: Self.diagnostics,
          "component=collection event=early-structural-reapply generation=%{public}d previous-rows=%{public}d rows=%{public}d elapsed-ms=%{public}d",
          generation,
          previousIDs.count,
          presentation.rows.count,
          Int((now - firstCompletedAt) * 1_000)
        )
      }
      lastCompletedStructuralIDs = presentation.orderedIDs
      tracePresentation(
        event: "complete",
        presentation: presentation,
        reason: nextUpdate == nil ? "settled" : "has-next",
        animated: false
      )
      schedulePresentationVerification(generation: generation)
    }
  }

  private func performPendingDisplayUpdateIfNeeded() {
    guard snapshotApplyInFlight == false,
          disclosureTransition == nil,
          isCompletingDisplayUpdate == false,
          let pendingDisplayUpdate,
          dataSource != nil,
          hasAppliedInitialSnapshot || hasUsableInitialViewport
    else { return }
    self.pendingDisplayUpdate = nil
    performDisplayUpdate(pendingDisplayUpdate)
  }

  private var hasUsableInitialViewport: Bool {
    let viewport = scrollView.contentView.bounds
    return hasCompletedViewLayout && viewport.width > 1 && viewport.height > 1
  }

  private func tracePresentation(
    event: String,
    presentation: SidebarBodyPresentation,
    reason: String,
    animated: Bool
  ) {
    var chatCount = 0
    var folderCount = 0
    var headerCount = 0
    var guideCount = 0
    var chromeCount = 0
    for row in presentation.rows {
      switch row.kind {
      case .chat:
        chatCount += 1
      case .folder:
        folderCount += 1
      case .sectionHeader, .timelineHeader, .archiveHeader:
        headerCount += 1
      case .pinDropGuide:
        guideCount += 1
      case .allChats, .grid, .folderEmpty, .newThread, .emptyState:
        chromeCount += 1
      }
    }
    let viewport = scrollView.contentView.bounds
    os_log(
      .info,
      log: Self.diagnostics,
      "component=collection event=%{public}@ generation=%{public}d reason=%{public}@ rows=%{public}d chats=%{public}d folders=%{public}d headers=%{public}d guides=%{public}d chrome=%{public}d animated=%{public}d viewport-w=%{public}d viewport-h=%{public}d",
      event as NSString,
      presentation.generation,
      reason as NSString,
      presentation.rows.count,
      chatCount,
      folderCount,
      headerCount,
      guideCount,
      chromeCount,
      animated ? 1 : 0,
      Int(viewport.width.rounded()),
      Int(viewport.height.rounded())
    )
  }

  #if DEBUG
  private func traceTransitionScene(
    event: String,
    generation: Int,
    reason: String
  ) {
    os_log(
      .debug,
      log: SidebarCollectionTransitionDiagnostics.log,
      "component=collection event=%{public}@ generation=%{public}d reason=%{public}@ snapshot-in-flight=%{public}d snapshot-owns-animations=%{public}d visible-items=%{public}d",
      event as NSString,
      generation,
      reason as NSString,
      snapshotApplyInFlight ? 1 : 0,
      snapshotApplyOwnsAnimations ? 1 : 0,
      collectionView.visibleItems().count
    )
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      item.traceTransitionState(event: event)
    }
  }
  #endif

  private func traceViewport(event: String) {
    let viewport = scrollView.contentView.bounds
    os_log(
      .debug,
      log: Self.diagnostics,
      "component=collection event=viewport-%{public}@ generation=%{public}d viewport-w=%{public}d viewport-h=%{public}d document-h=%{public}d visible-items=%{public}d",
      event as NSString,
      presentation?.generation ?? 0,
      Int(viewport.width.rounded()),
      Int(viewport.height.rounded()),
      Int(collectionView.frame.height.rounded()),
      collectionView.visibleItems().count
    )
  }

  private func schedulePresentationVerification(generation: Int? = nil) {
    guard let presentation else { return }
    let generation = generation ?? presentation.generation
    scheduledVerificationGeneration = generation
    DispatchQueue.main.async { [weak self] in
      guard let self,
            scheduledVerificationGeneration == generation,
            self.presentation?.generation == generation
      else { return }
      scheduledVerificationGeneration = nil
      collectionView.layoutSubtreeIfNeeded()
      collectionView.displayIfNeeded()
      verifyPresentationMaterialization(generation: generation)
    }
  }

  private func verifyPresentationMaterialization(generation: Int) {
    guard let dataSource, let presentation else { return }
    guard reorderSession == nil,
          localSettle == nil,
          disclosureTransition == nil
    else { return }
    let snapshotCount = dataSource.snapshot().itemIdentifiers.count
    let expectedCount = presentation.orderedIDs.count
    let representedIndexPaths = Set(collectionView.visibleItems().compactMap {
      collectionView.indexPath(for: $0)
    })
    let viewport = scrollView.contentView.bounds
    let expectedVisibleIndexPaths = Set<IndexPath>(
      layout.layoutAttributesForElements(in: viewport).compactMap { attributes in
        guard attributes.alpha > 0.01,
              attributes.isHidden == false,
              attributes.frame.intersects(viewport)
        else { return nil }
        return attributes.indexPath
      }
    )
    let missingVisibleCount = expectedVisibleIndexPaths.subtracting(representedIndexPaths).count
    let noninteractiveVisibleCount = collectionView.visibleItems().reduce(into: 0) { count, candidate in
      guard let item = candidate as? SidebarCollectionBodyItem,
            let indexPath = collectionView.indexPath(for: item),
            expectedVisibleIndexPaths.contains(indexPath),
            item.acceptsPointerInteraction == false
      else { return }
      count += 1
    }
    let visibleCount = representedIndexPaths.count
    let snapshotMatches = snapshotCount == expectedCount
    let geometryValid = viewport.width > 1
      && viewport.height > 1
      && abs(collectionView.frame.width - viewport.width) <= 1

    if snapshotMatches == false || geometryValid == false || missingVisibleCount > 0
      || noninteractiveVisibleCount > 0 {
      os_log(
        .error,
        log: Self.diagnostics,
        "component=collection event=verification-failed generation=%{public}d expected=%{public}d snapshot=%{public}d expected-visible=%{public}d visible-items=%{public}d missing-visible=%{public}d noninteractive-visible=%{public}d geometry-valid=%{public}d viewport-w=%{public}d viewport-h=%{public}d document-w=%{public}d",
        generation,
        expectedCount,
        snapshotCount,
        expectedVisibleIndexPaths.count,
        visibleCount,
        missingVisibleCount,
        noninteractiveVisibleCount,
        geometryValid ? 1 : 0,
        Int(viewport.width.rounded()),
        Int(viewport.height.rounded()),
        Int(collectionView.frame.width.rounded())
      )
      os_signpost(
        .event,
        log: Self.signposts,
        name: "SidebarPresentationDefect",
        "generation=%{public}d expected=%{public}d snapshot=%{public}d missingVisible=%{public}d noninteractiveVisible=%{public}d",
        generation,
        expectedCount,
        snapshotCount,
        missingVisibleCount,
        noninteractiveVisibleCount
      )
    } else {
      os_log(
        .debug,
        log: Self.diagnostics,
        "component=collection event=verified generation=%{public}d rows=%{public}d expected-visible=%{public}d visible-items=%{public}d",
        generation,
        expectedCount,
        expectedVisibleIndexPaths.count,
        visibleCount
      )
    }
  }

  /// Diffable completion means its model transaction is settled, but AppKit
  /// can still retain an outgoing reusable item or a stale presentation layer
  /// at a moved index path. That produces both the double-painted navigation
  /// rows and the visible-but-noninteractive rows caught by diagnostics. Keep
  /// normal animated updates intact; rematerialize only a proven bad settled
  /// scene, plus the deliberately atomic mode/resize and collapse commits.
  private func reconcileSettledVisibleItems(
    generation: Int,
    forceReload: Bool
  ) {
    guard let dataSource, let presentation else { return }

    var seenIndexPaths = Set<IndexPath>()
    var invalidItemCount = 0
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      guard let indexPath = collectionView.indexPath(for: item),
            let expectedRowID = dataSource.itemIdentifier(for: indexPath)
      else {
        invalidItemCount += 1
        continue
      }
      if seenIndexPaths.insert(indexPath).inserted == false
        || item.representedRowID != expectedRowID
        || (isLayoutVisible(at: indexPath) && item.acceptsPointerInteraction == false) {
        invalidItemCount += 1
      }
    }

    guard forceReload || invalidItemCount > 0 else { return }
    os_log(
      invalidItemCount > 0 ? .error : .info,
      log: Self.diagnostics,
      "component=collection event=settled-rematerialize generation=%{public}d rows=%{public}d invalid-visible=%{public}d forced=%{public}d",
      generation,
      presentation.rows.count,
      invalidItemCount,
      forceReload ? 1 : 0
    )

    // `reloadData()` refreshes semantic ownership, but AppKit can preserve the
    // model/presentation frame animation of a surviving reusable item (for
    // example Grid moving from index 0 to 1). Cancel both the pre-reload and
    // rematerialized item layers so an atomic update cannot keep painting the
    // old slot after its snapshot is already authoritative.
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      item.clearDisclosurePresentation()
    }
    collectionView.reloadData()
    collectionView.needsLayout = true
    collectionView.layoutSubtreeIfNeeded()
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      item.clearDisclosurePresentation()
    }
    collectionView.displayIfNeeded()
  }

  // MARK: - Hosted row refresh

  private func refreshVisibleContent(_ scope: VisibleRefreshScope) {
    if case .none = scope { return }
    refreshVisibleContentRows(scope)
  }

  private func refreshVisibleContentRows(_ scope: VisibleRefreshScope) {
    guard let content else { return }
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      guard let rowID = item.representedRowID,
            shouldRefresh(rowID, for: scope),
            let row = rowForHosting(rowID)
      else { continue }
      item.configure(
        row: row,
        content: { hostState in
          content(row, self.renderContext(for: row), hostState)
        },
        nativeConfiguration: renderer == .appKit
          ? nativeContent?(row, renderContext(for: row))
          : nil,
        isLayoutVisible: collectionView.indexPath(for: item).map(isLayoutVisible(at:))
          ?? true,
        preservesCollectionTransition: snapshotApplyOwnsAnimations,
        panHandler: { [weak self] rowID, state, location, translation in
          self?.handlePan(
            rowID: rowID,
            state: state,
            location: location,
            translation: translation
          )
        }
      )
    }
  }

  private func shouldRefresh(
    _ rowID: SidebarCollectionRow.ID,
    for scope: VisibleRefreshScope
  ) -> Bool {
    switch scope {
    case .none:
      false
    case let .rowIDs(rowIDs):
      rowIDs.contains(rowID)
    case .all:
      true
    }
  }

  private func renderContext(
    for row: SidebarCollectionRow
  ) -> SidebarCollectionRowRenderContext {
    let disclosureExpandedOverride: Bool? = if let transition = disclosureTransition,
                                               transition.identity.ownerID == row.id {
      transition.targetProgress > 0.5
    } else {
      nil
    }
    return SidebarCollectionRowRenderContext(
      dimsPinDropInstruction: row.id == .pinDropGuide
        && reorderSession?.pinDropInstructionIsDimmed == true,
      forceHoverAppearance: false,
      isDropTargeted: row.id.folderID == reorderSession?.proposal?.slot.parentID?.folderID,
      disclosureExpandedOverride: disclosureExpandedOverride,
      suppressesAnimations: isSidebarLiveResizeActive
    )
  }

  private func isLayoutVisible(at indexPath: IndexPath) -> Bool {
    guard let attributes = layout.layoutAttributesForItem(at: indexPath) else { return true }
    return attributes.alpha > 0.01 && attributes.frame.height > 0.5
  }

  private func disableInteractionForRowsLeavingSnapshot(
    _ retainedRowIDs: [SidebarCollectionRow.ID]
  ) {
    let retained = Set(retainedRowIDs)
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      guard let rowID = item.representedRowID,
            retained.contains(rowID) == false
      else { continue }
      item.disableInteractionForSnapshotRemoval()
    }
  }

  private func mergeRefreshScopes(
    _ lhs: VisibleRefreshScope,
    _ rhs: VisibleRefreshScope
  ) -> VisibleRefreshScope {
    switch (lhs, rhs) {
    case (.all, _), (_, .all):
      .all
    case (.none, let scope), (let scope, .none):
      scope
    case let (.rowIDs(lhsIDs), .rowIDs(rhsIDs)):
      .rowIDs(lhsIDs.union(rhsIDs))
    }
  }

  private func removing(
    _ rowIDs: Set<SidebarCollectionRow.ID>,
    from scope: VisibleRefreshScope
  ) -> VisibleRefreshScope {
    guard rowIDs.isEmpty == false else { return scope }
    switch scope {
    case .none, .all:
      return scope
    case let .rowIDs(scopeIDs):
      let remaining = scopeIDs.subtracting(rowIDs)
      return remaining.isEmpty ? .none : .rowIDs(remaining)
    }
  }

  private func changedSectionHeaderIDs(
    from previous: SidebarBodyPresentation?,
    to next: SidebarBodyPresentation
  ) -> Set<SidebarCollectionRow.ID> {
    guard let previous else { return [] }
    return Set(SidebarCollectionRow.SectionHeader.allCases.compactMap { section in
      let rowID = SidebarCollectionRow.ID.sectionHeader(section)
      guard let previousHeader = previous.rowByID[rowID],
            let nextHeader = next.rowByID[rowID],
            previousHeader != nextHeader
      else { return nil }
      return rowID
    })
  }

  private func refreshScope(
    from previous: SidebarBodyPresentation?,
    to next: SidebarBodyPresentation
  ) -> VisibleRefreshScope {
    guard let previous else { return .all }

    let oldRenderState = previous.renderState
    let newRenderState = next.renderState
    if oldRenderState.titlesDimmed != newRenderState.titlesDimmed
      || oldRenderState.sidebarAsInbox != newRenderState.sidebarAsInbox
      || oldRenderState.archiveVisible != newRenderState.archiveVisible
      || oldRenderState.preview.itemSize != newRenderState.preview.itemSize
      || oldRenderState.preview.unreadBadgeStyle != newRenderState.preview.unreadBadgeStyle
      || oldRenderState.preview.colorScheme != newRenderState.preview.colorScheme
      || oldRenderState.preview.themeRevision != newRenderState.preview.themeRevision
      || oldRenderState.preview.renderer != newRenderState.preview.renderer {
      return .all
    }

    var rowIDs = Set<SidebarCollectionRow.ID>(next.rows.compactMap { row in
      guard let previousRow = previous.rowByID[row.id] else { return nil }
      return previousRow == row ? nil : row.id
    })

    if oldRenderState.allChatsSelected != newRenderState.allChatsSelected
      || oldRenderState.scopedProminentUnreadCount != newRenderState.scopedProminentUnreadCount
      || oldRenderState.scopedOtherUnreadCount != newRenderState.scopedOtherUnreadCount {
      rowIDs.insert(.allChats)
    }

    if oldRenderState.gridSelectionKey != newRenderState.gridSelectionKey
      || oldRenderState.homeGridAvatarIDs != newRenderState.homeGridAvatarIDs {
      rowIDs.insert(.grid)
    }

    if oldRenderState.externalDropTargetID != newRenderState.externalDropTargetID {
      if let oldID = oldRenderState.externalDropTargetID {
        rowIDs.insert(.chat(oldID))
      }
      if let newID = newRenderState.externalDropTargetID {
        rowIDs.insert(.chat(newID))
      }
    }

    if oldRenderState.preview.temporaryItemID != newRenderState.preview.temporaryItemID {
      if let oldID = oldRenderState.preview.temporaryItemID {
        rowIDs.insert(.chat(oldID))
      }
      if let newID = newRenderState.preview.temporaryItemID {
        rowIDs.insert(.chat(newID))
      }
    }

    if oldRenderState.selectedPeer != newRenderState.selectedPeer
      || oldRenderState.selectedReplyPeer != newRenderState.selectedReplyPeer {
      let selectedPeers = [
        oldRenderState.selectedPeer,
        oldRenderState.selectedReplyPeer,
        newRenderState.selectedPeer,
        newRenderState.selectedReplyPeer,
      ].compactMap { $0 }
      for row in previous.rows + next.rows {
        guard let item = row.projectedItem,
              selectedPeers.contains(item.item.peerId)
        else { continue }
        rowIDs.insert(row.id)
      }
    }

    return rowIDs.isEmpty ? .none : .rowIDs(rowIDs)
  }

  private func layoutGeometryChanged(
    from previous: SidebarBodyPresentation?,
    to next: SidebarBodyPresentation
  ) -> Bool {
    guard let previous,
          previous.rows.count == next.rows.count
    else { return true }

    return zip(previous.rows, next.rows).contains { oldRow, newRow in
      oldRow.id != newRow.id
        || oldRow.height != newRow.height
        || oldRow.presentationLane != newRow.presentationLane
    }
  }

  private func unreadViewportInputsChanged(
    from previous: SidebarBodyPresentation?,
    to next: SidebarBodyPresentation
  ) -> Bool {
    guard let previous,
          previous.orderedIDs == next.orderedIDs
    else { return true }
    return next.rows.contains { row in
      if let item = row.projectedItem,
         let oldItem = previous.rowByID[row.id]?.projectedItem {
        return item.item.unread != oldItem.item.unread
          || item.item.prominentUnreadDot != oldItem.item.prominentUnreadDot
      }
      if let folder = row.projectedFolder,
         let oldFolder = previous.rowByID[row.id]?.projectedFolder {
        return folder.prominentUnreadCount != oldFolder.prominentUnreadCount
      }
      return false
    }
  }

  private var currentLayoutDrag: SidebarBodyLayoutDrag? {
    guard let session = reorderSession, let proposal = session.proposal else { return nil }
    let pinnedRootIDs = session.tree.snapshot.sections
      .first(where: { $0.id == .pinned })?
      .rootIDs ?? []
    let hidesPinnedHeader = proposal.targetLane != .pinned
      && pinnedRootIDs == [session.source.nodeID]
    return SidebarBodyLayoutDrag(
      sourceIDs: Set(session.draggedBlockIDs),
      destinationIndex: proposal.destinationIndex,
      // The pointer phase always lifts one immutable visible group. Even when
      // crossing a lane will eventually pin/unpin only the head, narrowing the
      // hole before mouse-up makes the preview and collection disagree and
      // pulls every row below it upward. Resolve that semantic split at drop;
      // never mutate the visible drag payload underneath the cursor.
      slotHeight: session.initialPreviewFrame.height,
      hidesPinnedHeader: hidesPinnedHeader
    )
  }

  private var currentEmptyPinnedLayout: SidebarCollectionEmptyPinnedLayoutState? {
    let isRevealed = reorderSession?.showsEmptyPinnedSection == true
      || localSettle?.keepsEmptyPinnedSection == true
    guard isRevealed else { return nil }
    return SidebarCollectionEmptyPinnedLayoutState(
      headerHeight: Double(emptyPinnedHeaderHeight),
      targetHeight: Double(SidebarCollectionRow.emptyPinnedTargetHeight)
    )
  }

  private var emptyPinnedHeaderHeight: CGFloat {
    let presentsSimplifiedInboxHierarchy = latestRenderState?.sidebarAsInbox == true
      && latestRenderState?.archiveVisible == false
    return presentsSimplifiedInboxHierarchy
      ? SidebarCollectionRow.pinnedSpacerHeight
      : SidebarCollectionRow.pinnedSectionHeaderHeight
  }

  private func configureLayout(
    for presentation: SidebarBodyPresentation,
    disclosure: SidebarBodyLayoutDisclosure? = nil,
    invalidatesLayout: Bool = true
  ) {
    unreadViewportEntries = nil
    let drag = currentLayoutDrag
    let emptyPinned = currentEmptyPinnedLayout
    let settlingSourceIDs = localSettle?.sourceIDs ?? []
    configuredLayoutDrag = drag
    configuredEmptyPinned = emptyPinned
    configuredLayoutDisclosure = disclosure
    configuredSettlingSourceIDs = settlingSourceIDs
    layout.configure(
      presentation: presentation,
      drag: drag,
      emptyPinned: emptyPinned,
      disclosure: disclosure,
      settlingSourceIDs: settlingSourceIDs,
      invalidatesLayout: invalidatesLayout
    )
  }

  private var layoutInteractionConfigurationChanged: Bool {
    configuredLayoutDrag != currentLayoutDrag
      || configuredEmptyPinned != currentEmptyPinnedLayout
      || configuredLayoutDisclosure != currentDisclosureLayout
      || configuredSettlingSourceIDs != (localSettle?.sourceIDs ?? [])
  }

  private var currentDisclosureLayout: SidebarBodyLayoutDisclosure? {
    guard let transition = disclosureTransition else { return nil }
    return transition.geometry.layoutState(
      hidesAffectedRows: transition.phase == .stagingExpansion
    )
  }

  private var previewHorizontalBleed: CGFloat {
    0
  }

  // MARK: - Interaction routing

  private func handlePan(
    rowID: SidebarCollectionRow.ID,
    state: NSGestureRecognizer.State,
    location: CGPoint,
    translation: CGPoint
  ) {
    switch state {
    case .began:
      beginReorder(rowID: rowID, location: location, translation: translation)
    case .changed:
      updateReorder(location: location, translation: translation)
    case .ended:
      finishReorder()
    case .cancelled, .failed:
      cancelReorder(animated: true, reason: "gesture-cancelled")
    case .possible:
      break
    @unknown default:
      cancelReorder(animated: false, reason: "unknown-gesture-state")
    }
  }

  // MARK: - External file drops

  private func updateExternalDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard supportsExternalAttachments(sender.draggingPasteboard),
          reorderSession == nil,
          disclosureTransition == nil,
          let targetID = externalDropTarget(at: sender.draggingLocation),
          let target = actions?.externalDropTarget(targetID)
    else {
      endExternalDrop(sequence: sender.draggingSequenceNumber)
      return []
    }

    if externalDropState.updateHover(
      sequenceID: sender.draggingSequenceNumber,
      targetID: target
    ) {
      actions?.externalDropTargetChanged(target.rowID)
      log.debug("external-drop target changed sequence=\(sender.draggingSequenceNumber)")
    }
    return .copy
  }

  private func performExternalDrop(_ sender: NSDraggingInfo) -> Bool {
    guard supportsExternalAttachments(sender.draggingPasteboard) else {
      endExternalDrop(sequence: sender.draggingSequenceNumber)
      return false
    }
    let currentChatIDs: Set<ChatListItem.Identifier> = Set(
      presentation?.rows.compactMap(\.projectedItem?.id) ?? []
    )
    let acceptsActiveSequence = externalDropState.sequenceID == sender.draggingSequenceNumber
    let target = externalDropState.accept(
      sequenceID: sender.draggingSequenceNumber,
      validating: { currentChatIDs.contains($0.rowID) }
    )
    if acceptsActiveSequence {
      actions?.externalDropTargetChanged(nil)
    }
    guard let target else {
      log.info(
        "external-drop rejected missing or disappeared target "
          + "sequence=\(sender.draggingSequenceNumber)"
      )
      return false
    }

    let accepted = actions?.performExternalDrop(target, sender.draggingPasteboard) ?? false
    log.info(
      "external-drop performed sequence=\(sender.draggingSequenceNumber) accepted=\(accepted)"
    )
    return accepted
  }

  private func endExternalDrop(sequence: Int?) {
    guard externalDropState.end(sequenceID: sequence) else { return }
    actions?.externalDropTargetChanged(nil)
  }

  private func externalDropTarget(at windowPoint: CGPoint) -> ChatListItem.Identifier? {
    let point = collectionView.convert(windowPoint, from: nil)
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      guard item.view.frame.contains(point),
            let rowID = item.representedRowID,
            case let .chat(id) = rowID
      else { continue }
      return id
    }
    return nil
  }

  private func supportsExternalAttachments(_ pasteboard: NSPasteboard) -> Bool {
    guard let types = pasteboard.types else { return false }
    return InlinePasteboard.draggedTypes.contains(where: types.contains)
  }

  // MARK: - Internal reorder lifecycle

  private func beginReorder(
    rowID: SidebarCollectionRow.ID,
    location: CGPoint,
    translation: CGPoint
  ) {
    guard let externalTree else { return }
    let tree = optimisticState.map {
      externalTree.replacing(snapshot: $0.presented)
    } ?? externalTree

    guard reorderSession == nil,
          localSettle == nil,
          snapshotApplyInFlight == false,
          disclosureTransition == nil,
          isCompletingDisplayUpdate == false,
          pendingDisplayUpdate == nil,
          let sourceRow = rowForHosting(rowID),
          let source = ReorderSource(sourceRow),
          source.supports(reorderPolicy),
          source.orderLane != nil,
          reorderPolicy == .manual || source.parentID == nil,
          // A reply inherited into a pinned parent's presentation lane keeps
          // its own persisted order lane. Until those order domains are
          // decoupled, do not offer a drag whose apparent move would also
          // mutate pin state or immediately snap back into the parent.
          source.parentID?.folderID != nil
            || source.parentID == nil
            || source.orderLane == source.lane,
          let dragGroup = try? tree.snapshot.dragGroup(for: source.nodeID),
          let allLegalSlots = try? tree.snapshot.legalSlots(for: source.nodeID),
          let window = collectionView.window
    else { return }

    // Pinned parents own their reply presentation. Same-lane replies may
    // still reorder as siblings, but a root destination would claim to detach
    // and then immediately be overridden by the projection invariant.
    let legalSlots: [ModelSlot]
    switch source {
    case .folder:
      // Dialog folders are one-level root containers. The generic `.any`
      // child policy accepts chats, but must never imply nested folders.
      legalSlots = allLegalSlots.filter {
        $0.parentID == nil
      }
    case let .chat(item):
      if item.parentID?.folderID != nil {
        // Folder members may move between folders or return to the normal
        // root, but never become a pinned root as a side effect of dragging.
        legalSlots = allLegalSlots.filter {
          !($0.sectionID == .pinned && $0.parentID == nil)
        }
      } else {
        legalSlots = item.parentID != nil && item.lane == .pinned
          ? allLegalSlots.filter { $0.parentID == item.parentID }
          : allLegalSlots
      }
    }

    collectionView.layoutSubtreeIfNeeded()
    let rowIDs = displayRows.map(\.id)
    let blockIDs = dragGroup.visibleNodeIDs.compactMap(rowID(for:))
    let stableFrames: [SidebarCollectionRow.ID: CGRect] = Dictionary(
      uniqueKeysWithValues: rowIDs.enumerated().compactMap { index, id -> (SidebarCollectionRow.ID, CGRect)? in
        guard let frame = layout.layoutAttributesForItem(
          at: IndexPath(item: index, section: 0)
        )?.frame else { return nil }
        return (id, frame)
      }
    )
    let projectedHitGuides = displayRows.compactMap { row -> ProjectedHitGuide? in
      guard let nodeID = row.projectedNodeID,
            var frame = stableFrames[row.id]
      else { return nil }
      if case let .folder(folder) = row.kind,
         let emptyFrame = stableFrames[.folderEmpty(folder.id)] {
        frame = frame.union(emptyFrame)
      }
      return ProjectedHitGuide(
        nodeID: nodeID,
        parentID: row.presentationParentID,
        isContainer: tree.snapshot.nodes[nodeID]?.childPolicy != SidebarCollectionChildPolicy.none,
        minY: frame.minY,
        middleY: frame.midY,
        maxY: frame.maxY
      )
    }
    let projectedVerticalHitGuides = projectedHitGuides.map {
      SidebarCollectionVerticalHitGuide(
        minY: Double($0.minY),
        middleY: Double($0.middleY),
        maxY: Double($0.maxY)
      )
    }
    guard let groupFrame = frameUnion(for: blockIDs, frames: stableFrames),
          let dragPreviewContent
    else { return }

    let currentScreenPoint = screenPoint(for: location) ?? NSEvent.mouseLocation
    let startPointInCollection = CGPoint(
      x: location.x - translation.x,
      y: location.y - translation.y
    )
    let startScreenPoint = screenPoint(for: startPointInCollection) ?? currentScreenPoint
    let initialPreviewFrame = window.convertToScreen(collectionView.convert(groupFrame, to: nil))
    let grabOffsetY = min(
      max(startPointInCollection.y - groupFrame.minY, 0),
      groupFrame.height
    )
    let pinnedRootIDs = tree.snapshot.sections
      .first(where: { $0.id == .pinned })?
      .rootIDs ?? []
    let firstNormalRootFrame = tree.snapshot.sections
      .first(where: { $0.id == .normal })?
      .rootIDs
      .lazy
      .compactMap { self.rowID(for: $0).flatMap { stableFrames[$0] } }
      .first
    let id = UUID()
    var session = ReorderSession(
      id: id,
      source: source,
      tree: tree,
      dragGroup: dragGroup,
      legalSlots: Set(legalSlots),
      originalRows: displayRows,
      originalRowIDs: rowIDs,
      rowByID: Dictionary(uniqueKeysWithValues: displayRows.map { ($0.id, $0) }),
      indexByRowID: Dictionary(
        uniqueKeysWithValues: rowIDs.enumerated().map { ($0.element, $0.offset) }
      ),
      draggedBlockIDs: blockIDs,
      stableFrames: stableFrames,
      startScreenPoint: startScreenPoint,
      initialPreviewFrame: initialPreviewFrame,
      grabOffsetY: grabOffsetY,
      pointerScreenPoint: currentScreenPoint,
      pointerInCollection: location,
      projectedHitGuides: projectedHitGuides,
      projectedVerticalHitGuides: projectedVerticalHitGuides,
      pinBoundaryY: layout.laneBoundaryFrame?.minY,
      emptyPinnedRevealThresholdY: firstNormalRootFrame?.midY,
      canRevealEmptyPinnedSection: pinnedRootIDs.isEmpty
        && firstNormalRootFrame != nil,
      reorderPolicy: reorderPolicy,
      originalProposal: nil,
      proposal: nil
    )
    session.rawRootProposals = rootProposals(session: session).filter {
      session.legalSlots.contains($0.slot)
    }
    let containerIDs = Set(allLegalSlots.compactMap(\.parentID))
    let legalChildProposals = containerIDs.flatMap { parentID in
      childProposals(parentID: parentID, session: session)
    }.filter { session.legalSlots.contains($0.slot) }
    session.rawChildProposals = switch reorderPolicy {
    case .manual:
      legalChildProposals
    case .pinningOnly:
      legalChildProposals.filter {
        $0.targetLane == .pinned && $0.slot.parentID?.folderID != nil
      }
    }
    refreshProposalGroups(session: &session)
    let allProposals: [Proposal] = session.rootProposals.proposals
      + session.childProposals.proposals
    session.originalProposal = allProposals.first { proposal in
      session.tree.snapshot.isNode(session.source.nodeID, at: proposal.slot)
    }
    guard let originalProposal = session.originalProposal else {
      log.error(
        "drag[\(String(id.uuidString.prefix(6)))] missing frozen source slot"
      )
      return
    }
    // Never let pointer proximity reorder on lift. The first scene is exactly
    // the source's semantic position with one equal-sized replacement hole.
    session.proposal = originalProposal
    _ = updateEmptyPinnedSectionVisibility(session: &session)
    reorderSession = session
    if let folderID = session.proposal?.slot.parentID?.folderID {
      refreshVisibleContent(.rowIDs([.folder(folderID)]))
    }
    let nativeDragPreviewContent: (
      (SidebarCollectionRow) -> SidebarNativeRowConfiguration
    )? = if renderer == .appKit, let nativeContent {
      { row in nativeContent(row, .dragPreview) }
    } else {
      nil
    }
    previewPanel.show(
      rows: blockIDs.compactMap { session.rowByID[$0] },
      content: dragPreviewContent,
      nativeContent: nativeDragPreviewContent,
      horizontalBleed: previewHorizontalBleed,
      ownerWindow: window,
      frame: previewFrame(for: session)
    )
    updateLayoutForReorder(animated: false)
    installCancellationHooks()
    startAutoscroll()
    let dragID = String(id.uuidString.prefix(6))
    let visibleCount = session.dragGroup.visibleNodeIDs.count
    let attachedCount = session.dragGroup.attachedNodeIDs.count
    let startsCollapsed = source.isExpandable && source.isExpanded == false
    let policyDescription = String(describing: reorderPolicy)
    log.info(
      "drag[\(dragID)] began visibleRows=\(visibleCount) attachedRows=\(attachedCount) "
        + "collapsed=\(startsCollapsed) policy=\(policyDescription)"
    )
  }

  private func updateReorder(location _: CGPoint, translation _: CGPoint) {
    guard var session = reorderSession, session.isSettling == false else { return }
    let previousDropTargetFolderID = session.proposal?.slot.parentID?.folderID
    // Gesture locations are event-time samples and can lag after a brief main
    // thread stall. Screen cursor state is the authoritative current pointer.
    resamplePointer(for: &session)
    let emptyPinnedVisibilityChanged = updateEmptyPinnedSectionVisibility(
      session: &session
    )
    let proposalChanged = acceptProposal(
      at: session.pointerInCollection,
      session: &session
    )
    reorderSession = session
    let dropTargetFolderID = session.proposal?.slot.parentID?.folderID

    if emptyPinnedVisibilityChanged || proposalChanged {
      updateLayoutForReorder(animated: true)
    }
    let pinInstructionChanged = updatePinDropInstructionDimming(session: &session)
    reorderSession = session
    if emptyPinnedVisibilityChanged || proposalChanged || pinInstructionChanged {
      var rowIDs: Set<SidebarCollectionRow.ID> = [.pinDropGuide]
      if let previousDropTargetFolderID { rowIDs.insert(.folder(previousDropTargetFolderID)) }
      if let dropTargetFolderID { rowIDs.insert(.folder(dropTargetFolderID)) }
      refreshVisibleContent(.rowIDs(rowIDs))
    }
    if proposalChanged {
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    previewPanel.move(
      to: previewFrame(for: session).origin,
      horizontalBleed: previewHorizontalBleed
    )
  }

  private func acceptProposal(
    at point: CGPoint,
    session: inout ReorderSession
  ) -> Bool {
    guard let candidate = nearestProposal(at: point, session: session),
          candidate.slot != session.proposal?.slot
    else { return false }

    let hierarchyChanged = session.proposal?.slot.parentID != candidate.slot.parentID
    session.proposal = candidate
    if hierarchyChanged {
      updateDragPreview(for: session)
    }
    log.debug(
      "drag[\(String(session.id.uuidString.prefix(6)))] proposal accepted "
        + "destination=\(String(describing: candidate.slot))"
    )
    return true
  }

  private func updateDragPreview(for session: ReorderSession) {
    guard let proposal = session.proposal,
          let dragPreviewContent,
          let sourceRow = session.rowByID[session.source.rowID],
          let sourceDepth = sourceRow.presentationDepth
    else { return }

    let destinationDepth: Int
    if let parentID = proposal.slot.parentID {
      guard let parentRowID = rowID(for: parentID),
            let parentDepth = session.rowByID[parentRowID]?.presentationDepth
      else { return }
      destinationDepth = parentDepth + 1
    } else {
      destinationDepth = 0
    }
    let depthOffset = destinationDepth - sourceDepth
    let rows = session.draggedBlockIDs.compactMap { rowID -> SidebarCollectionRow? in
      guard let row = session.rowByID[rowID] else { return nil }
      switch row.kind {
      case let .chat(item):
        let item = SidebarProjectedItem(
          item: item.item,
          depth: max(item.depth + depthOffset, 0),
          semanticParentID: item.semanticParentID,
          parentID: row.id == session.source.rowID ? proposal.slot.parentID : item.parentID,
          orderLane: item.orderLane,
          lane: proposal.targetLane,
          childCount: item.childCount,
          isExpanded: item.isExpanded
        )
        return SidebarCollectionRow(id: row.id, kind: .chat(item), height: row.height)
      case let .folder(folder):
        let folder = SidebarProjectedFolder(
          folder: folder.folder,
          depth: max(folder.depth + depthOffset, 0),
          lane: proposal.targetLane,
          childCount: folder.childCount,
          unreadCount: folder.unreadCount,
          prominentUnreadCount: folder.prominentUnreadCount,
          isExpanded: folder.isExpanded
        )
        return SidebarCollectionRow(id: row.id, kind: .folder(folder), height: row.height)
      default:
        return nil
      }
    }
    guard rows.count == session.draggedBlockIDs.count else { return }

    let transitioningNativeContent: (
      (SidebarCollectionRow) -> SidebarNativeRowConfiguration
    )? = if renderer == .appKit, let nativeContent {
      { row in nativeContent(row, .transitioningDragPreview) }
    } else {
      nil
    }
    previewPanel.update(
      rows: rows,
      content: dragPreviewContent,
      nativeContent: transitioningNativeContent,
      horizontalBleed: previewHorizontalBleed
    )
  }

  private func finishReorder() {
    guard let session = reorderSession, session.isSettling == false else { return }
    guard let proposal = session.proposal else {
      cancelReorder(animated: true, reason: "missing-proposal")
      return
    }

    if let latestSnapshot = externalTree?.snapshot {
      _ = reconcileOptimisticState(with: latestSnapshot)
    }
    var state = optimisticState ?? OptimisticState(confirmed: session.tree.snapshot)
    let moveTree = (externalTree ?? session.tree).replacing(snapshot: state.presented)
    guard let move = collectionMove(
      for: session,
      proposal: proposal,
      tree: moveTree
    ),
          let slotFrame = layout.slotFrame,
          let targetScreenFrame = collectionView.window?.convertToScreen(
            collectionView.convert(slotFrame, to: nil)
          )
    else {
      cancelReorder(animated: true, reason: "unchanged")
      return
    }

    do {
      try state.beginMove(
        id: session.id,
        sourceID: session.source.nodeID,
        destination: proposal.slot,
        scope: .attachedSubtree
      )
    } catch {
      log.error(
        "drag[\(String(session.id.uuidString.prefix(6)))] model move rejected: "
          + "\(String(describing: error))"
      )
      cancelReorder(animated: true, reason: "invalid-model-move")
      return
    }
    optimisticState = state

    stopAutoscroll()
    removeCancellationHooks()

    // Pin persistence changes only the source dialog, but the sidebar's
    // presentation tree still owns its semantic reply subtree. Keep those two
    // scopes separate: the optimistic collection scene and lifted preview move
    // the complete visible group on frame one, while `collectionMove` retains
    // the root-only persistence contract for a cross-lane transfer.
    let settlingSourceIDs = Set(session.draggedBlockIDs)
    let pending = PendingMove(
      id: session.id,
      sourceID: session.source.rowID,
      sourceIDs: settlingSourceIDs,
      targetLane: proposal.targetLane
    )
    removePendingMoves(forSourceID: pending.sourceID)
    pendingMoves.append(pending)
    localSettle = LocalSettle(
      id: session.id,
      sourceIDs: settlingSourceIDs,
      keepsEmptyPinnedSection: session.showsEmptyPinnedSection
        && proposal.targetLane != .pinned
    )
    reorderSession = nil

    let finalRows = presentationRows(
      snapshot: state.presented,
      tree: externalTree ?? session.tree,
      basedOn: externalRows,
      pendingMoves: pendingMoves
    )
    requestDisplayRows(
      finalRows,
      // The panel owns the moved row until settlement, so diffable can safely
      // animate every other structural change underneath it. In particular,
      // populating an empty Pinned lane now fades/collapses the teaching guide
      // instead of replacing it with the real row in one unanimated frame.
      animatingDifferences: true,
      reason: "optimistic-drop"
    ) { [weak self] in
      self?.markLocalSettlePresentationFinished(id: session.id)
    }

    actions?.move(move) { [weak self] success in
      self?.handleMoveCompletion(id: pending.id, success: success)
    }

    log.info(
      "drag[\(String(session.id.uuidString.prefix(6)))] dropped "
        + "destination=\(String(describing: proposal.slot))"
    )
    previewPanel.settle(
      to: targetScreenFrame,
      horizontalBleed: previewHorizontalBleed
    ) { [weak self] in
      self?.markLocalSettlePreviewFinished(id: session.id)
    }
  }

  // MARK: - Optimistic reconciliation

  private func markLocalSettlePreviewFinished(id: UUID) {
    guard var settle = localSettle, settle.id == id else { return }
    settle.previewFinished = true
    localSettle = settle
    finishLocalSettleIfReady(id: id)
  }

  private func markLocalSettlePresentationFinished(id: UUID) {
    guard var settle = localSettle, settle.id == id else { return }
    settle.presentationFinished = true
    localSettle = settle
    finishLocalSettleIfReady(id: id)
  }

  private func finishLocalSettleIfReady(id: UUID) {
    guard var settle = localSettle,
          settle.id == id,
          settle.previewFinished,
          settle.presentationFinished
    else { return }

    // The lifted panel owns the pixels until it reaches the exact final slot.
    // Hide it before allowing the collection item to render, then perform the
    // conditional-section dismissal as a separate layout transition.
    previewPanel.hide()
    settle.sourceIDs = []
    localSettle = settle
    updateLayoutForReorder(animated: false)
    finishConditionalEmptyPinnedHandoff(id: id)
  }

  private func finishConditionalEmptyPinnedHandoff(id: UUID) {
    guard let settle = localSettle,
          settle.id == id,
          settle.sourceIDs.isEmpty
    else { return }

    guard settle.keepsEmptyPinnedSection else {
      localSettle = nil
      finishLocalPresentation()
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self,
            let current = localSettle,
            current.id == id,
            current.sourceIDs.isEmpty
      else { return }
      localSettle = nil
      updateLayoutForReorder(animated: true)
    }
  }

  private func handleMoveCompletion(id: UUID, success: Bool) {
    guard pendingMoves.contains(where: { $0.id == id }) else { return }
    if success {
      guard var state = optimisticState else {
        log.warning("drag[\(String(id.uuidString.prefix(6)))] missing optimistic move")
        removePendingMoves(ids: [id])
        requestDisplayRows(
          optimisticPresentationRows(),
          animatingDifferences: false,
          reason: "optimistic-state-missing"
        )
        return
      }
      guard state.acknowledgeRPC(id: id) else {
        log.warning("drag[\(String(id.uuidString.prefix(6)))] missing optimistic intent")
        removePendingMoves(ids: [id])
        requestDisplayRows(
          optimisticPresentationRows(),
          animatingDifferences: false,
          reason: "optimistic-intent-missing"
        )
        return
      }
      optimisticState = state
      log.debug("drag[\(String(id.uuidString.prefix(6)))] persistence completed")
      if state.pendingMoves.contains(where: { $0.id == id }) == false {
        removePendingMoves(ids: [id])
        requestDisplayRows(
          optimisticPresentationRows(),
          animatingDifferences: false,
          reason: "optimistic-acknowledged"
        )
      } else {
        schedulePendingObservationNotice(id: id, after: .seconds(8))
      }
      return
    }

    log.warning("drag[\(String(id.uuidString.prefix(6)))] persistence failed; rolling back")
    let presentationChanged: Bool
    if var state = optimisticState {
      presentationChanged = state.failMove(id: id)
      optimisticState = state
    } else {
      presentationChanged = false
    }
    removePendingMoves(ids: [id])
    if localSettle?.id == id {
      localSettle = nil
      previewPanel.hide()
    }
    if reorderSession?.id == id {
      cancelReorder(animated: false, reason: "persistence-failed")
    } else if presentationChanged {
      requestDisplayRows(
        optimisticPresentationRows(),
        animatingDifferences: true,
        reason: "optimistic-rollback"
      )
    }
  }

  private func schedulePendingObservationNotice(
    id: UUID,
    after duration: Duration
  ) {
    pendingMoveObservationTasks[id]?.cancel()
    pendingMoveObservationTasks[id] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: duration)
      } catch {
        return
      }
      guard let self,
            pendingMoves.contains(where: { $0.id == id }),
            optimisticState?.pendingMoves.contains(where: { $0.id == id }) == true
      else { return }
      log.warning(
        "drag[\(String(id.uuidString.prefix(6)))] still awaiting model observation after persistence"
      )
    }
  }

  private func reconcileOptimisticState(
    with snapshot: SidebarCollectionTree.Snapshot
  ) -> SidebarCollectionReconciliation? {
    guard pendingMoves.isEmpty == false else {
      optimisticState = OptimisticState(confirmed: snapshot)
      return nil
    }
    var state = optimisticState ?? OptimisticState(confirmed: snapshot)
    let reconciliation = state.receiveExternal(snapshot)
    optimisticState = state

    let completedIDs = Set(
      reconciliation.acknowledgedMoveIDs + reconciliation.cancelledMoveIDs
    )
    if completedIDs.isEmpty == false {
      removePendingMoves(ids: completedIDs)
    }
    if let settle = localSettle,
       reconciliation.cancelledMoveIDs.contains(settle.id) {
      localSettle = nil
      previewPanel.hide()
    }
    return reconciliation
  }

  private func removePendingMoves(forSourceID sourceID: SidebarCollectionRow.ID) {
    let supersededIDs = Set(
      pendingMoves.lazy.filter { $0.sourceID == sourceID }.map(\.id)
    )
    removePendingMoves(ids: supersededIDs)
  }

  private func removePendingMoves<S: Sequence>(ids: S) where S.Element == UUID {
    let ids = Set(ids)
    guard ids.isEmpty == false else { return }
    pendingMoves.removeAll { ids.contains($0.id) }
    for id in ids {
      pendingMoveObservationTasks.removeValue(forKey: id)?.cancel()
    }
  }

  private func clearPendingMoves() {
    pendingMoves.removeAll()
    for task in pendingMoveObservationTasks.values {
      task.cancel()
    }
    pendingMoveObservationTasks.removeAll()
  }

  private func optimisticPresentationRows() -> [SidebarCollectionRow] {
    guard let optimisticState, let externalTree else { return externalRows }
    return presentationRows(
      snapshot: optimisticState.presented,
      tree: externalTree,
      basedOn: externalRows,
      pendingMoves: pendingMoves
    )
  }

  private func presentationRows(
    snapshot: SidebarCollectionTree.Snapshot,
    tree: SidebarCollectionTree,
    basedOn baseRows: [SidebarCollectionRow],
    pendingMoves: [PendingMove]
  ) -> [SidebarCollectionRow] {
    var laneOverrides: [ChatListItem.Identifier: SidebarOrderLane] = [:]
    for pendingMove in pendingMoves {
      if case let .chat(sourceID) = pendingMove.sourceID {
        laneOverrides[sourceID] = pendingMove.targetLane
      }
    }
    let rowHeight = baseRows.first(where: { $0.projectedItem != nil })?.height
      ?? baseRows.first(where: { $0.id == .newThread })?.height
      ?? 44
    let projectedNodes = tree
      .replacing(snapshot: snapshot)
      .projectedNodes(orderLaneOverrides: laneOverrides)
    func nodeRows(_ nodes: [SidebarProjectedNode]) -> [SidebarCollectionRow] {
      nodes.flatMap { node -> [SidebarCollectionRow] in
        switch node {
        case let .chat(item):
          return [SidebarCollectionRow(
            id: .chat(item.id),
            kind: .chat(item),
            height: baseRows.first(where: { $0.id == .chat(item.id) })?.height ?? rowHeight
          )]
        case let .folder(folder):
          var rows = [SidebarCollectionRow(
            id: .folder(folder.id),
            kind: .folder(folder),
            height: baseRows.first(where: { $0.id == .folder(folder.id) })?.height ?? rowHeight
          )]
          if folder.childCount == 0, folder.isExpanded {
            rows.append(SidebarCollectionRow(
              id: .folderEmpty(folder.id),
              kind: .folderEmpty(folder.id, lane: folder.lane),
              height: baseRows.first(where: { $0.id == .folderEmpty(folder.id) })?.height
                ?? rowHeight
            ))
          }
          return rows
        }
      }
    }
    let pinnedRows = nodeRows(projectedNodes.filter { $0.lane == .pinned })
    let contentNodes = projectedNodes.filter { $0.lane == .normal }
    let usesTimelineSections = baseRows.contains {
      $0.id == .sectionHeader(.content)
    } == false
    let contentRows = usesTimelineSections
      ? SidebarCollectionRow.timelineRows(
        contentNodes.compactMap(\.projectedItem),
        chatRowHeight: rowHeight
      )
      : nodeRows(contentNodes)
    let pinnedExpanded = baseRows.first(where: { $0.id == .sectionHeader(.pinned) })?
      .sectionHeader?.isExpanded ?? true
    let contentExpanded = baseRows.first(where: { $0.id == .sectionHeader(.content) })?
      .sectionHeader?.isExpanded ?? true
    let presentsSimplifiedInboxHierarchy = latestRenderState?.sidebarAsInbox == true
      && latestRenderState?.archiveVisible == false
    // Recompute latent lane geometry from optimistic membership so the first
    // pin or open chat gets its spacing on the same frame as the moved row.
    let pinnedHeaderHeight = presentsSimplifiedInboxHierarchy
      ? (pinnedRows.isEmpty ? 0 : SidebarCollectionRow.pinnedSpacerHeight)
      : (baseRows.first(where: { $0.id == .sectionHeader(.pinned) })?.height
        ?? SidebarCollectionRow.pinnedSectionHeaderHeight)
    let contentHeaderHeight = presentsSimplifiedInboxHierarchy
      ? (contentNodes.isEmpty ? 0 : SidebarCollectionRow.openSeparatorHeight)
      : (baseRows.first(where: { $0.id == .sectionHeader(.content) })?.height
        ?? SidebarCollectionRow.spacedSectionHeaderHeight)
    // Optimistic moves rebuild chat membership, but the base projection still
    // owns whether New Thread leads or trails the content lane. In All Chats,
    // the action is navigation chrome before every organizational lane—not
    // merely a row before the chronological timeline.
    let newThreadIndex = baseRows.firstIndex(where: { $0.id == .newThread })
    let newThreadRow = newThreadIndex.map { baseRows[$0] }
    let newThreadLeadsContent = newThreadLeadsContent(in: baseRows)
    var logicalRows: [SidebarCollectionRow] = []
    if usesTimelineSections, newThreadLeadsContent, let newThreadRow {
      logicalRows.append(newThreadRow)
    }
    if pinnedRows.isEmpty == false {
      logicalRows.append(.sectionHeader(
        .pinned,
        isExpanded: pinnedExpanded,
        height: pinnedHeaderHeight
      ))
      if pinnedExpanded {
        logicalRows.append(contentsOf: pinnedRows)
      }
    } else {
      // Stable latent identities let the layout reveal the empty-Pinned target
      // without changing collection content or rehosting the active row.
      logicalRows.append(.sectionHeader(.pinned, isExpanded: true, height: 0))
      logicalRows.append(.pinDropGuide())
    }
    if usesTimelineSections {
      logicalRows.append(contentsOf: contentRows)
    } else {
      logicalRows.append(.sectionHeader(
        .content,
        isExpanded: contentExpanded,
        height: contentHeaderHeight
      ))
      if newThreadLeadsContent, let newThreadRow {
        logicalRows.append(newThreadRow)
      }
      if contentExpanded {
        logicalRows.append(contentsOf: contentRows)
      }
    }
    if newThreadLeadsContent == false, let newThreadRow {
      logicalRows.append(newThreadRow)
    }

    var result: [SidebarCollectionRow] = []
    var insertedLogicalRows = false
    for row in baseRows {
      if row.projectedNodeID != nil || row.isSectionHeader || row.isTimelineHeader
        || row.id == .pinDropGuide || row.id == .newThread {
        if insertedLogicalRows == false {
          result.append(contentsOf: logicalRows)
          insertedLogicalRows = true
        }
        continue
      }
      result.append(row)
    }
    if insertedLogicalRows == false {
      result.append(contentsOf: logicalRows)
    }
    return result
  }

  private func rowsWithLatentEmptyPinnedGuide(
    _ rows: [SidebarCollectionRow]
  ) -> [SidebarCollectionRow] {
    guard rows.contains(where: { $0.id == .sectionHeader(.pinned) }) == false else {
      return rows
    }

    var stableRows = rows
    let insertionIndex = rows.firstIndex(where: { $0.id == .sectionHeader(.content) })
      ?? rows.firstIndex(where: \.isTimelineHeader)
      ?? rows.firstIndex(where: { $0.projectedNodeID != nil })
      ?? rows.endIndex
    stableRows.insert(contentsOf: [
      .sectionHeader(.pinned, isExpanded: true, height: 0),
      .pinDropGuide(height: 0),
    ], at: insertionIndex)
    return stableRows
  }

  // MARK: - Reorder presentation

  private func cancelReorder(animated: Bool, reason: String) {
    guard var session = reorderSession else { return }
    stopAutoscroll()
    removeCancellationHooks()

    let finish = { [weak self] in
      guard let self, reorderSession?.id == session.id else { return }
      // The panel is the sole source renderer through the return animation.
      // Transfer ownership only after it reaches the open source slot.
      previewPanel.hide()
      reorderSession = nil
      localSettle = LocalSettle(
        id: session.id,
        sourceIDs: [],
        keepsEmptyPinnedSection: session.showsEmptyPinnedSection,
        previewFinished: true,
        presentationFinished: true
      )
      updateLayoutForReorder(animated: false)
      if let latestSnapshot = externalTree?.snapshot {
        _ = reconcileOptimisticState(with: latestSnapshot)
      }
      requestDisplayRows(
        optimisticPresentationRows(),
        animatingDifferences: false,
        reason: "drag-cancelled"
      ) { [weak self] in
        self?.finishConditionalEmptyPinnedHandoff(id: session.id)
      }
    }
    if animated {
      // Return the one hole to the source before the lifted preview settles.
      // Keeping the previous destination open until the preview arrives was a
      // two-step cancellation: destination closed, then source reappeared.
      if let originalProposal = session.originalProposal,
         session.proposal?.slot != originalProposal.slot {
        let hierarchyChanged = session.proposal?.slot.parentID
          != originalProposal.slot.parentID
        session.proposal = originalProposal
        if hierarchyChanged {
          updateDragPreview(for: session)
        }
      }
      session.isSettling = true
      reorderSession = session
      updateLayoutForReorder(animated: true)
      let targetFrame = layout.slotFrame.flatMap { slotFrame in
        collectionView.window?.convertToScreen(
          collectionView.convert(slotFrame, to: nil)
        )
      } ?? session.initialPreviewFrame
      previewPanel.settle(
        to: targetFrame,
        horizontalBleed: previewHorizontalBleed,
        completion: finish
      )
    } else {
      finish()
    }
    log.debug("drag[\(String(session.id.uuidString.prefix(6)))] cancelled reason=\(reason)")
  }

  private func updateLayoutForReorder(animated: Bool) {
    guard let presentation else { return }
    let oldPresentations = visiblePresentations()
    configureLayout(for: presentation)
    collectionView.needsLayout = true
    collectionView.layoutSubtreeIfNeeded()
    updateScrollEdges(animated: false)

    guard animated,
          NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    else { return }

    let hiddenIDs = Set(reorderSession?.draggedBlockIDs ?? [])
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      guard let rowID = item.representedRowID else { continue }
      guard hiddenIDs.contains(rowID) == false,
            let oldPresentation = oldPresentations[rowID],
            let layer = item.view.layer
      else { continue }

      let newFrame = item.view.frame
      let presentedY = oldPresentation.modelFrame.minY + oldPresentation.translationY
      let deltaY = presentedY - newFrame.minY
      layer.removeAnimation(forKey: "sidebar-slot-move")
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = CATransform3DIdentity
      CATransaction.commit()

      let targetOpacity = Float(item.view.alphaValue)
      if abs(oldPresentation.opacity - targetOpacity) > 0.01 {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = oldPresentation.opacity
        fade.toValue = targetOpacity
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "sidebar-slot-fade")
      }

      guard abs(deltaY) > 0.5 else { continue }
      let animation = CABasicAnimation(keyPath: "transform")
      animation.fromValue = NSValue(
        caTransform3D: CATransform3DMakeTranslation(0, deltaY, 0)
      )
      animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
      animation.duration = 0.16
      animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
      layer.add(animation, forKey: "sidebar-slot-move")
    }
  }

  private func visiblePresentations() -> [SidebarCollectionRow.ID: VisiblePresentation] {
    Dictionary(
      uniqueKeysWithValues: collectionView.visibleItems().compactMap { rawItem in
        guard let item = rawItem as? SidebarCollectionBodyItem,
              let rowID = item.representedRowID
        else { return nil }
        let layer = item.view.layer
        let translationY = layer?.presentation()?.transform.m42 ?? layer?.transform.m42 ?? 0
        let opacity = layer?.presentation()?.opacity
          ?? layer?.opacity
          ?? Float(item.view.alphaValue)
        return (
          rowID,
          VisiblePresentation(
            modelFrame: item.view.frame,
            translationY: translationY,
            opacity: opacity
          )
        )
      }
    )
  }

  private func finishLocalPresentation() {
    if let presentation {
      configureLayout(for: presentation)
      collectionView.needsLayout = true
    }
    collectionView.layoutSubtreeIfNeeded()
    updateScrollEdges(animated: false)
    for item in collectionView.visibleItems() {
      guard let layer = item.view.layer else { continue }
      layer.removeAnimation(forKey: "sidebar-slot-move")
      layer.removeAnimation(forKey: "sidebar-slot-fade")
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = CATransform3DIdentity
      CATransaction.commit()
    }
    previewPanel.hide()
  }

  private func captureViewportAnchor(
    survivingIn rowIDs: Set<SidebarCollectionRow.ID>
  ) -> ViewportAnchor? {
    let viewportTop = scrollView.contentView.bounds.minY
    return collectionView.visibleItems()
      .compactMap { rawItem -> (SidebarCollectionRow.ID, CGFloat)? in
        guard let item = rawItem as? SidebarCollectionBodyItem,
              let rowID = item.representedRowID,
              rowIDs.contains(rowID),
              item.view.frame.maxY > viewportTop
        else { return nil }
        return (rowID, item.view.frame.minY)
      }
      .min(by: { $0.1 < $1.1 })
      .map { rowID, minY in
        ViewportAnchor(rowID: rowID, offsetFromViewportTop: minY - viewportTop)
      }
  }

  private func captureViewportAnchor(
    rowID: SidebarCollectionRow.ID
  ) -> ViewportAnchor? {
    guard let item = visibleItem(for: rowID) else { return nil }
    return ViewportAnchor(
      rowID: rowID,
      offsetFromViewportTop: item.view.frame.minY - scrollView.contentView.bounds.minY
    )
  }

  private func restoreViewportAnchor(_ anchor: ViewportAnchor?) {
    guard let anchor,
          let dataSource,
          let index = dataSource.snapshot().itemIdentifiers.firstIndex(of: anchor.rowID),
          let frame = layout.layoutAttributesForItem(
            at: IndexPath(item: index, section: 0)
          )?.frame
    else { return }

    let visible = scrollView.contentView.bounds
    let maximumY = max(layout.collectionViewContentSize.height - visible.height, 0)
    let targetY = min(max(frame.minY - anchor.offsetFromViewportTop, 0), maximumY)
    guard abs(targetY - visible.minY) > 0.5 else { return }
    scrollView.contentView.scroll(to: CGPoint(x: visible.minX, y: targetY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func previewFrame(for session: ReorderSession) -> CGRect {
    let horizontalDelta: CGFloat = switch dragPreviewMotion {
    case .railed:
      0
    case .freeform:
      session.pointerScreenPoint.x - session.startScreenPoint.x
    }
    let delta = CGPoint(
      x: horizontalDelta,
      y: session.pointerScreenPoint.y - session.startScreenPoint.y
    )
    return session.initialPreviewFrame.offsetBy(dx: delta.x, dy: delta.y)
  }

  private func updatePinDropInstructionDimming(
    session: inout ReorderSession
  ) -> Bool {
    let shouldDim: Bool = {
      guard session.showsEmptyPinnedSection,
            let window = collectionView.window,
            let presentation,
            let index = presentation.orderedIDs.firstIndex(of: .pinDropGuide),
            let attributes = layout.layoutAttributesForItem(
              at: IndexPath(item: index, section: 0)
            ),
            attributes.alpha > 0.01,
            attributes.frame.height > 0
      else { return false }

      let guideFrame = window.convertToScreen(
        collectionView.convert(attributes.frame, to: nil)
      )
      // The copy is centered with about ten points of breathing room. Dim it
      // only when the lifted row covers the instructional content itself; it
      // remains visible so the destination never loses its meaning mid-drag.
      let instructionFrame = guideFrame.insetBy(dx: 0, dy: 10)
      return previewFrame(for: session).intersects(instructionFrame)
    }()

    guard shouldDim != session.pinDropInstructionIsDimmed else { return false }
    session.pinDropInstructionIsDimmed = shouldDim
    return true
  }

  private func screenPoint(for point: CGPoint) -> CGPoint? {
    guard let window = collectionView.window else { return nil }
    return window.convertPoint(toScreen: collectionView.convert(point, to: nil))
  }

  private func frameUnion(
    for rowIDs: [SidebarCollectionRow.ID],
    frames: [SidebarCollectionRow.ID: CGRect]
  ) -> CGRect? {
    rowIDs.reduce(into: CGRect?.none) { result, rowID in
      guard let frame = frames[rowID] else { return }
      result = result.map { $0.union(frame) } ?? frame
    }
  }

  // MARK: - Proposal geometry

  private func nearestProposal(at point: CGPoint, session: ReorderSession) -> Proposal? {
    let candidates: ProposalGroup
    if let childCandidates = childProposalGroup(at: point, session: session) {
      candidates = childCandidates
    } else {
      candidates = rootProposals(at: point, session: session)
    }
    // Guides describe the destination's leading edge. Resolve against the
    // lifted group's leading edge, not the arbitrary place inside the row
    // where the user happened to press.
    let liftedLeadingY = point.y - session.grabOffsetY
    return nearestProposal(
      to: liftedLeadingY,
      in: candidates,
      current: session.proposal,
      hysteresis: 4
    )
  }

  private func nearestProposal(
    to position: CGFloat,
    in group: ProposalGroup,
    current: Proposal?,
    hysteresis: CGFloat
  ) -> Proposal? {
    let proposals = group.proposals
    let currentIndex = current.flatMap { group.indexBySlot[$0.slot] }
    guard let index = SidebarCollectionSortedPositionResolver.resolve(
      position: Double(position),
      sortedPositions: group.positions,
      currentIndex: currentIndex,
      hysteresis: Double(hysteresis)
    ) else { return nil }
    return proposals[index]
  }

  private func rootProposals(at point: CGPoint, session: ReorderSession) -> ProposalGroup {
    guard let boundary = session.pinBoundaryY else { return session.rootProposals }
    let liftedLeadingY = point.y - session.grabOffsetY
    let currentLane = session.proposal?.targetLane ?? session.source.orderLane ?? .normal
    let lane: SidebarOrderLane
    switch currentLane {
    case .pinned where liftedLeadingY <= boundary + 4:
      lane = .pinned
    case .normal where liftedLeadingY >= boundary - 4:
      lane = .normal
    default:
      lane = liftedLeadingY < boundary ? .pinned : .normal
    }
    let proposals = lane == .pinned
      ? session.pinnedRootProposals
      : session.normalRootProposals
    return proposals.isEmpty ? session.rootProposals : proposals
  }

  private func childProposalGroup(
    at point: CGPoint,
    session: ReorderSession
  ) -> ProposalGroup? {
    guard let target = closestProjectedGuide(toY: point.y, session: session) else { return nil }

    let availableParentIDs = Set(session.childProposals.proposals.compactMap { $0.slot.parentID })
    let parentID: SidebarCollectionNodeID?
    if target.isContainer, availableParentIDs.contains(target.nodeID) {
      parentID = target.nodeID
    } else if point.x >= childDropIndentThreshold,
              let targetParentID = target.parentID,
              availableParentIDs.contains(targetParentID) {
      parentID = targetParentID
    } else if point.x >= childDropIndentThreshold,
              target.nodeID == session.source.nodeID,
              let sourceParentID = session.source.parentID,
              availableParentIDs.contains(sourceParentID) {
      parentID = sourceParentID
    } else {
      parentID = nil
    }
    guard let parentID else { return nil }
    let proposals = session.childProposals.proposals.filter {
      $0.slot.parentID == parentID
    }
    return proposals.isEmpty ? nil : ProposalGroup(proposals)
  }

  private var childDropIndentThreshold: CGFloat {
    Theme.sidebarNativeDefaultEdgeInsets + Theme.sidebarItemInnerSpacing + 12
  }

  private func closestProjectedGuide(
    toY y: CGFloat,
    session: ReorderSession
  ) -> ProjectedHitGuide? {
    let guides = session.projectedHitGuides
    let index = SidebarCollectionVerticalHitResolver.resolve(
      position: Double(y),
      sortedGuides: session.projectedVerticalHitGuides
    )
    return index.map { guides[$0] }
  }

  private func rootProposals(session: ReorderSession) -> [Proposal] {
    let reducedRows = ReducedRows(
      removing: Set(session.draggedBlockIDs),
      from: session.originalRowIDs
    )
    let roots = reducedRows.ids.compactMap { rowID -> ProjectedRootGuide? in
      guard let row = session.rowByID[rowID],
            let nodeID = row.projectedNodeID,
            row.presentationParentID == nil,
            let orderLane = session.tree.orderLaneByID[nodeID] ?? row.presentationLane
      else {
        return nil
      }
      return ProjectedRootGuide(rowID: rowID, nodeID: nodeID, orderLane: orderLane)
    }
    let pinned = roots.filter { $0.orderLane == .pinned }
    let normal = roots.filter { $0.orderLane == .normal }
    var proposals: [Proposal] = []
    let firstGuideY = firstRootGuideY(roots, session: session)

    appendRootProposals(
      roots: pinned,
      lane: .pinned,
      fallbackGuideY: normalLaneBoundaryFrame(session: session)?.minY
        ?? firstGuideY,
      reducedRows: reducedRows,
      session: session,
      to: &proposals
    )
    appendRootProposals(
      roots: normal,
      lane: .normal,
      fallbackGuideY: normalLaneBoundaryFrame(session: session)?.maxY
        ?? lastRootGuideY(roots, session: session),
      reducedRows: reducedRows,
      session: session,
      to: &proposals
    )

    if let boundary = session.pinBoundaryY {
      replaceBoundaryGuides(in: &proposals, boundary: boundary)
    }

    return proposals
  }

  private func pinningOnlyProposals(
    from proposals: [Proposal],
    session: ReorderSession
  ) -> [Proposal] {
    if case .folder = session.source {
      return folderPinningOnlyProposals(from: proposals, session: session)
    }
    guard let sourceLane = session.source.orderLane else { return [] }
    let targetLane: SidebarOrderLane = sourceLane == .pinned ? .normal : .pinned
    let sourceProposal = proposals.first { proposal in
      proposal.targetLane == sourceLane
        && session.tree.snapshot.isNode(session.source.nodeID, at: proposal.slot)
    }
    let targetProposal = activityOwnedLaneTransferProposal(
      to: targetLane,
      from: proposals,
      session: session
    )

    return [sourceProposal, targetProposal].compactMap { $0 }
  }

  private func folderPinningOnlyProposals(
    from proposals: [Proposal],
    session: ReorderSession
  ) -> [Proposal] {
    guard let sourceLane = session.source.orderLane else { return [] }
    let normalRoots = session.tree.snapshot.sections
      .first(where: { $0.id == .normal })?
      .rootIDs
      .filter { $0 != session.source.nodeID } ?? []
    let firstActivityRoot = normalRoots.first { nodeID in
      if case .chat = nodeID { return true }
      return false
    }
    var normalFolderProposals = proposals.filter { proposal in
      guard proposal.targetLane == .normal,
            proposal.slot.parentID == nil
      else { return false }
      switch proposal.slot.beforeSiblingID {
      case .folder?:
        return true
      case let beforeSiblingID?:
        return beforeSiblingID == firstActivityRoot
      case nil:
        return firstActivityRoot == nil
      }
    }
    if normalFolderProposals.isEmpty,
       let collapsedLaneProposal = proposals.first(where: { proposal in
         // A collapsed Open section exposes one section-level guide. The
         // folder projection will still place the transferred root before its
         // activity-sorted chats when the section expands.
         proposal.targetLane == .normal
           && proposal.slot.parentID == nil
           && proposal.slot.beforeSiblingID == nil
       }) {
      normalFolderProposals.append(collapsedLaneProposal)
    }

    var candidates = normalFolderProposals
    if sourceLane == .pinned {
      if let sourceProposal = proposals.first(where: { proposal in
        proposal.targetLane == .pinned
          && session.tree.snapshot.isNode(session.source.nodeID, at: proposal.slot)
      }) {
        candidates.append(sourceProposal)
      }
    } else if let pinnedProposal = activityOwnedLaneTransferProposal(
      to: .pinned,
      from: proposals,
      session: session
    ) {
      candidates.append(pinnedProposal)
    }

    var seen = Set<ModelSlot>()
    return candidates.filter { seen.insert($0.slot).inserted }
  }

  private func activityOwnedLaneTransferProposal(
    to targetLane: SidebarOrderLane,
    from proposals: [Proposal],
    session: ReorderSession
  ) -> Proposal? {
    let targetRoots = session.tree.snapshot.sections
      .first(where: { $0.id == targetLane })?
      .rootIDs
      .filter { $0 != session.source.nodeID } ?? []
    let beforeSiblingID = targetRoots.first { targetID in
      groupIsOrderedBefore(
        session.source.nodeID,
        targetID,
        tree: session.tree
      )
    }
    return proposals.first { proposal in
      proposal.targetLane == targetLane
        && proposal.slot.parentID == nil
        && proposal.slot.beforeSiblingID == beforeSiblingID
    } ?? proposals.first { proposal in
      // A collapsed target section has only one measurable lane guide. Recent
      // activity owns the final order, so the section-level slot is sufficient.
      proposal.targetLane == targetLane
        && proposal.slot.parentID == nil
        && proposal.slot.beforeSiblingID == nil
    }
  }

  private func groupIsOrderedBefore(
    _ lhs: SidebarCollectionNodeID,
    _ rhs: SidebarCollectionNodeID,
    tree: SidebarCollectionTree
  ) -> Bool {
    let lhsActivity = groupActivity(lhs, tree: tree)
    let rhsActivity = groupActivity(rhs, tree: tree)
    if lhsActivity != rhsActivity {
      return lhsActivity > rhsActivity
    }
    return String(describing: lhs) > String(describing: rhs)
  }

  private func groupActivity(
    _ rootID: SidebarCollectionNodeID,
    tree: SidebarCollectionTree
  ) -> Date {
    let group = try? tree.snapshot.dragGroup(for: rootID)
    return group?.attachedNodeIDs.compactMap { nodeID in
      nodeID.chatID.flatMap { tree.itemByID[$0]?.lastActivityAt }
    }.max()
      ?? rootID.chatID.flatMap { tree.itemByID[$0]?.lastActivityAt }
      ?? .distantPast
  }

  private func appendRootProposals(
    roots: [ProjectedRootGuide],
    lane: SidebarOrderLane,
    fallbackGuideY: CGFloat,
    reducedRows: ReducedRows,
    session: ReorderSession,
    to proposals: inout [Proposal]
  ) {
    if roots.isEmpty {
      let insertionIndex: Int
      switch lane {
      case .pinned:
        insertionIndex = emptyLaneInsertionIndex(
          .pinned,
          in: reducedRows.ids,
          rows: session.originalRows
        )
      case .normal:
        insertionIndex = emptyLaneInsertionIndex(
          .normal,
          in: reducedRows.ids,
          rows: session.originalRows
        )
      }
      proposals.append(makeProposal(
        slot: ModelSlot(sectionID: lane, parentID: nil, beforeSiblingID: nil),
        insertionIndex: insertionIndex,
        guideY: fallbackGuideY,
        targetLane: lane,
        reducedIDs: reducedRows.ids
      ))
      return
    }

    for root in roots {
      guard let insertionIndex = reducedRows.indexByID[root.rowID],
            let frame = subtreeFrame(for: root.rowID, session: session)
      else { continue }
      proposals.append(makeProposal(
        slot: ModelSlot(sectionID: lane, parentID: nil, beforeSiblingID: root.nodeID),
        insertionIndex: insertionIndex,
        guideY: frame.minY,
        targetLane: lane,
        reducedIDs: reducedRows.ids
      ))
    }

    guard let last = roots.last,
          let lastIndex = reducedRows.indexByID[last.rowID],
          let frame = subtreeFrame(for: last.rowID, session: session)
    else { return }
    proposals.append(makeProposal(
      slot: ModelSlot(sectionID: lane, parentID: nil, beforeSiblingID: nil),
      insertionIndex: indexAfterSubtree(
        startingAt: lastIndex,
        in: reducedRows.ids,
        rowByID: session.rowByID
      ),
      guideY: frame.maxY,
      targetLane: lane,
      reducedIDs: reducedRows.ids
    ))
  }

  private func replaceBoundaryGuides(in proposals: inout [Proposal], boundary: CGFloat) {
    proposals = proposals.map { proposal in
      if proposal.slot.parentID == nil,
         proposal.slot.sectionID == .pinned,
         proposal.slot.beforeSiblingID == nil {
        Proposal(
          slot: proposal.slot,
          destinationIndex: proposal.destinationIndex,
          targetLane: proposal.targetLane,
          guideY: boundary - 3
        )
      } else if proposal.slot.parentID == nil,
                proposal.slot.sectionID == .normal,
                proposal.slot.beforeSiblingID != nil {
        Proposal(
          slot: proposal.slot,
          destinationIndex: proposal.destinationIndex,
          targetLane: proposal.targetLane,
          guideY: max(proposal.guideY, boundary + 3)
        )
      } else {
        proposal
      }
    }
  }

  private func emptyLaneInsertionIndex(
    _ lane: SidebarOrderLane,
    in rowIDs: [SidebarCollectionRow.ID],
    rows: [SidebarCollectionRow]
  ) -> Int {
    switch lane {
    case .pinned:
      if let pinnedHeader = rowIDs.firstIndex(of: .sectionHeader(.pinned)) {
        return pinnedHeader + 1
      }
      return rowIDs.firstIndex(of: .sectionHeader(.content))
        ?? rowIDs.firstIndex(where: { id in
          guard case .timelineHeader = id else { return false }
          return true
        })
        ?? firstChatIndex(in: rowIDs, rows: rows)
    case .normal:
      let chatInsertionIndex = rowIDs.firstIndex(of: .sectionHeader(.content)).map { $0 + 1 }
        ?? indexAfterLastChat(in: rowIDs, rows: rows)
      guard newThreadLeadsContent(in: rows),
            let newThreadIndex = rowIDs.firstIndex(of: .newThread)
      else { return chatInsertionIndex }
      // New Thread is fixed Open chrome, not a reorderable chat. When lifting
      // the lane's only chat, reserve the empty-lane hole after this action so
      // it never gets pushed to the trailing edge of the list.
      return max(chatInsertionIndex, newThreadIndex + 1)
    }
  }

  private func newThreadLeadsContent(
    in rows: [SidebarCollectionRow]
  ) -> Bool {
    guard let newThreadIndex = rows.firstIndex(where: { $0.id == .newThread }) else {
      return false
    }
    let usesTimelineSections = rows.contains {
      $0.id == .sectionHeader(.content)
    } == false
    if usesTimelineSections {
      let firstTimelineIndex = rows.firstIndex(where: { $0.isTimelineHeader })
        ?? rows.firstIndex(where: { $0.presentationLane == .normal })
        ?? rows.endIndex
      return newThreadIndex < firstTimelineIndex
    }

    let contentHeaderIndex = rows.firstIndex(where: {
      $0.id == .sectionHeader(.content)
    })
    let firstContentRowIndex = rows.indices.first { index in
      guard contentHeaderIndex.map({ index > $0 }) ?? true else { return false }
      let row = rows[index]
      return row.presentationLane == .normal || row.id == .emptyState
    } ?? rows.endIndex
    return newThreadIndex < firstContentRowIndex
  }

  private func sectionHeaderFrame(
    _ header: SidebarCollectionRow.SectionHeader,
    session: ReorderSession
  ) -> CGRect? {
    session.stableFrames[.sectionHeader(header)]
  }

  private func normalLaneBoundaryFrame(session: ReorderSession) -> CGRect? {
    if let contentHeaderFrame = sectionHeaderFrame(.content, session: session) {
      return contentHeaderFrame
    }
    guard let rowID = normalLaneBoundaryRowID(in: session.originalRows) else {
      return nil
    }
    return session.stableFrames[rowID]
  }

  private func normalLaneBoundaryRowID(
    in rows: [SidebarCollectionRow]
  ) -> SidebarCollectionRow.ID? {
    rows.first(where: \.isTimelineHeader)?.id
      ?? rows.first(where: { $0.presentationLane == .normal })?.id
  }

  private func childProposals(
    parentID: SidebarCollectionNodeID,
    session: ReorderSession
  ) -> [Proposal] {
    let block = Set(session.draggedBlockIDs)
    let reducedIDs = session.originalRowIDs.filter { block.contains($0) == false }
    let reducedIndexByID = Dictionary(
      uniqueKeysWithValues: reducedIDs.enumerated().map { ($0.element, $0.offset) }
    )
    let siblings = reducedIDs.compactMap { rowID ->
      (rowID: SidebarCollectionRow.ID, nodeID: SidebarCollectionNodeID, lane: SidebarOrderLane)? in
      guard let row = session.rowByID[rowID],
            let nodeID = row.projectedNodeID,
            row.presentationParentID == parentID,
            let lane = session.tree.orderLaneByID[nodeID]
              ?? row.presentationLane
              ?? session.source.orderLane
      else {
        return nil
      }
      return (rowID, nodeID, lane)
    }
    var proposals: [Proposal] = []
    guard let parentRowID = rowID(for: parentID) else { return [] }
    let sectionID = session.tree.snapshot.sectionID(containing: parentID) ?? nil
    let presentationLane = sectionID

    for sibling in siblings {
      guard let index = reducedIndexByID[sibling.rowID],
            let frame = session.stableFrames[sibling.rowID]
      else { continue }
      proposals.append(makeProposal(
        slot: ModelSlot(
          sectionID: sectionID,
          parentID: parentID,
          beforeSiblingID: sibling.nodeID
        ),
        insertionIndex: index,
        guideY: frame.minY,
        targetLane: presentationLane ?? sibling.lane,
        reducedIDs: reducedIDs
      ))
    }

    if let last = siblings.last,
       let index = reducedIndexByID[last.rowID],
       let frame = subtreeFrame(for: last.rowID, session: session) {
      proposals.append(makeProposal(
        slot: ModelSlot(
          sectionID: sectionID,
          parentID: parentID,
          beforeSiblingID: nil
        ),
        insertionIndex: indexAfterSubtree(
          startingAt: index,
          in: reducedIDs,
          rowByID: session.rowByID
        ),
        guideY: frame.maxY,
        targetLane: presentationLane ?? last.lane,
        reducedIDs: reducedIDs
      ))
    } else if let parentIndex = reducedIndexByID[parentRowID],
              let parentFrame = session.stableFrames[parentRowID],
              let targetLane = presentationLane
                ?? session.rowByID[parentRowID]?.presentationLane
                ?? session.source.orderLane {
      proposals.append(makeProposal(
        slot: ModelSlot(
          sectionID: sectionID,
          parentID: parentID,
          beforeSiblingID: nil
        ),
        insertionIndex: parentIndex + 1,
        guideY: parentFrame.maxY,
        targetLane: targetLane,
        reducedIDs: reducedIDs
      ))
    }
    return proposals
  }

  private func makeProposal(
    slot: ModelSlot,
    insertionIndex: Int,
    guideY: CGFloat,
    targetLane: SidebarOrderLane,
    reducedIDs: [SidebarCollectionRow.ID]
  ) -> Proposal {
    let safeIndex = min(max(insertionIndex, 0), reducedIDs.count)
    return Proposal(
      slot: slot,
      destinationIndex: safeIndex,
      targetLane: targetLane,
      guideY: guideY
    )
  }

  private func normalizedProposals(
    _ proposals: [Proposal],
    session: ReorderSession,
    revealsEmptyPinnedSection: Bool
  ) -> [Proposal] {
    guard proposals.isEmpty == false else { return [] }
    let pinnedRootIDs = session.tree.snapshot.sections
      .first(where: { $0.id == .pinned })?
      .rootIDs ?? []
    let plannedRows = plannedLayoutRows(for: session)
    let emptyPinned = revealsEmptyPinnedSection
      ? SidebarCollectionEmptyPinnedLayoutState(
        headerHeight: Double(emptyPinnedHeaderHeight),
        targetHeight: Double(SidebarCollectionRow.emptyPinnedTargetHeight)
      )
      : nil
    let sourceIDs = Set(session.draggedBlockIDs)
    let modes = Set(proposals.map { proposal in
      ProposalLayoutMode(
        revealsEmptyPinnedSection: revealsEmptyPinnedSection,
        hidesPinnedHeader: proposal.targetLane != .pinned
          && pinnedRootIDs == [session.source.nodeID]
      )
    })
    let slotPositionsByMode = Dictionary(uniqueKeysWithValues: modes.map { mode in
      (
        mode,
        SidebarCollectionDragLayoutPlanner.slotPositions(
          rows: plannedRows,
          sourceIDs: sourceIDs,
          emptyPinned: mode.revealsEmptyPinnedSection ? emptyPinned : nil,
          hidesPinnedHeader: mode.hidesPinnedHeader
        )
      )
    })

    return proposals.map { proposal in
      let mode = ProposalLayoutMode(
        revealsEmptyPinnedSection: revealsEmptyPinnedSection,
        hidesPinnedHeader: proposal.targetLane != .pinned
          && pinnedRootIDs == [session.source.nodeID]
      )
      return Proposal(
        slot: proposal.slot,
        destinationIndex: proposal.destinationIndex,
        targetLane: proposal.targetLane,
        guideY: CGFloat(
          slotPositionsByMode[mode]?[proposal.destinationIndex]
            ?? Double(proposal.guideY)
        )
      )
    }
  }

  private func plannedLayoutRows(
    for session: ReorderSession
  ) -> [SidebarCollectionDragLayoutRow<SidebarCollectionRow.ID>] {
    session.originalRows.map { row in
      let role: SidebarCollectionDragLayoutRowRole
      switch row.id {
      case .sectionHeader(.pinned):
        role = .pinnedHeader
      case .pinDropGuide:
        role = .emptyPinnedGuide
      case .folderEmpty:
        role = .emptyFolderGuide
      default:
        role = .ordinary
      }
      return SidebarCollectionDragLayoutRow(
        id: row.id,
        height: Double(row.height),
        role: role
      )
    }
  }

  private func refreshProposalGroups(session: inout ReorderSession) {
    let currentSlot = session.proposal?.slot
    let originalSlot = session.originalProposal?.slot
    var rootProposals = normalizedProposals(
      session.rawRootProposals,
      session: session,
      revealsEmptyPinnedSection: session.showsEmptyPinnedSection
    )
    if session.reorderPolicy == .pinningOnly {
      rootProposals = pinningOnlyProposals(
        from: rootProposals,
        session: session
      )
    }
    let childProposals = normalizedProposals(
      session.rawChildProposals,
      session: session,
      revealsEmptyPinnedSection: session.showsEmptyPinnedSection
    )
    session.rootProposals = ProposalGroup(rootProposals)
    session.pinnedRootProposals = ProposalGroup(
      rootProposals.filter { $0.targetLane == .pinned }
    )
    session.normalRootProposals = ProposalGroup(
      rootProposals.filter { $0.targetLane == .normal }
    )
    session.childProposals = ProposalGroup(childProposals)

    if session.showsEmptyPinnedSection {
      let plan = SidebarCollectionDragLayoutPlanner.plan(
        rows: plannedLayoutRows(for: session),
        drag: Optional<SidebarCollectionDragLayoutState<SidebarCollectionRow.ID>>.none,
        emptyPinned: SidebarCollectionEmptyPinnedLayoutState(
          headerHeight: Double(emptyPinnedHeaderHeight),
          targetHeight: Double(SidebarCollectionRow.emptyPinnedTargetHeight)
        )
      )
      let boundaryRowID = normalLaneBoundaryRowID(in: session.originalRows)
        ?? .sectionHeader(.content)
      session.pinBoundaryY = plan.rowFrames[boundaryRowID].map {
        CGFloat($0.minY)
      }
    } else {
      // The conditional section moves the semantic lane boundary. Restore the
      // frozen collapsed boundary when it dismisses; retaining the expanded
      // value would leave an invisible Pinned hit region over Inbox.
      session.pinBoundaryY = rootProposals.first(where: { proposal in
        proposal.slot.parentID == nil
          && proposal.slot.sectionID == .pinned
          && proposal.slot.beforeSiblingID == nil
      })?.guideY
    }

    let allProposals = session.rootProposals.proposals
      + session.childProposals.proposals
    if let originalSlot {
      session.originalProposal = allProposals.first { $0.slot == originalSlot }
    }
    if let currentSlot {
      session.proposal = allProposals.first { $0.slot == currentSlot }
        ?? session.originalProposal
    }
  }

  private func updateEmptyPinnedSectionVisibility(
    session: inout ReorderSession
  ) -> Bool {
    guard session.canRevealEmptyPinnedSection,
          let revealThresholdY = session.emptyPinnedRevealThresholdY
    else { return false }

    let shouldShow = SidebarConditionalSectionResolver.resolve(
      // Reveal only after the cursor itself crosses the frozen midpoint of
      // the first Inbox item. Using the lifted row's leading edge made a grab
      // near its bottom reveal Pinned before the user moved over that row.
      position: Double(session.pointerInCollection.y),
      entryThreshold: Double(revealThresholdY),
      // Once revealed, keep the section as real document geometry for the
      // remainder of this drag. Session teardown owns its removal after the
      // user drops or cancels, avoiding a moving target mid-interaction.
      isActive: session.showsEmptyPinnedSection,
      hysteresis: 4
    )
    guard shouldShow != session.showsEmptyPinnedSection else { return false }

    session.showsEmptyPinnedSection = shouldShow
    refreshProposalGroups(session: &session)
    log.debug(
      "drag[\(String(session.id.uuidString.prefix(6)))] "
        + "\(shouldShow ? "revealed" : "dismissed") empty Pinned section"
    )
    return true
  }

  private func firstRootGuideY(
    _ roots: [ProjectedRootGuide],
    session: ReorderSession
  ) -> CGFloat {
    roots.first.flatMap { subtreeFrame(for: $0.rowID, session: session)?.minY }
      ?? frameUnion(for: session.draggedBlockIDs, frames: session.stableFrames)?.minY
      ?? 0
  }

  private func lastRootGuideY(
    _ roots: [ProjectedRootGuide],
    session: ReorderSession
  ) -> CGFloat {
    roots.last.flatMap { subtreeFrame(for: $0.rowID, session: session)?.maxY }
      ?? frameUnion(for: session.draggedBlockIDs, frames: session.stableFrames)?.maxY
      ?? 0
  }

  private func subtreeFrame(
    for rowID: SidebarCollectionRow.ID,
    session: ReorderSession
  ) -> CGRect? {
    guard let index = session.indexByRowID[rowID],
          let sourceDepth = session.rowByID[rowID]?.presentationDepth
    else { return nil }
    var frame: CGRect?
    var cursor = index
    while session.originalRowIDs.indices.contains(cursor) {
      let currentID = session.originalRowIDs[cursor]
      if cursor != index {
        guard let depth = session.rowByID[currentID]?.presentationDepth,
              depth > sourceDepth else { break }
      }
      if let currentFrame = session.stableFrames[currentID] {
        frame = frame.map { $0.union(currentFrame) } ?? currentFrame
      }
      cursor += 1
    }
    return frame
  }

  private func indexAfterSubtree(
    startingAt start: Int,
    in rowIDs: [SidebarCollectionRow.ID],
    rowByID: [SidebarCollectionRow.ID: SidebarCollectionRow]
  ) -> Int {
    SidebarCollectionVisibleOutline.indexAfterSubtree(
      startingAt: start,
      depths: rowIDs.map { rowByID[$0]?.presentationDepth }
    )
  }

  private func firstChatIndex(
    in rowIDs: [SidebarCollectionRow.ID],
    rows: [SidebarCollectionRow]
  ) -> Int {
    let chatRowIDs = Set(rows.lazy.filter { $0.projectedNodeID != nil }.map(\.id))
    return rowIDs.firstIndex { chatRowIDs.contains($0) }
      ?? rowIDs.firstIndex(where: isTrailingRow) ?? rowIDs.count
  }

  private func indexAfterLastChat(
    in rowIDs: [SidebarCollectionRow.ID],
    rows: [SidebarCollectionRow]
  ) -> Int {
    let chatRowIDs = Set(rows.lazy.filter { $0.projectedNodeID != nil }.map(\.id))
    return rowIDs.lastIndex { chatRowIDs.contains($0) }.map { $0 + 1 }
      ?? firstChatIndex(in: rowIDs, rows: rows)
  }

  private func isTrailingRow(_ rowID: SidebarCollectionRow.ID) -> Bool {
    switch rowID {
    case .newThread, .emptyState:
      true
    default:
      false
    }
  }

  private func rowID(for id: SidebarCollectionNodeID) -> SidebarCollectionRow.ID? {
    switch id {
    case let .chat(chatID): .chat(chatID)
    case let .folder(folderID): .folder(folderID)
    }
  }

  private func collectionMove(
    for session: ReorderSession,
    proposal: Proposal,
    tree: SidebarCollectionTree
  ) -> SidebarCollectionMoveIntent? {
    let sourceNodeID = session.source.nodeID
    guard let sourceLane = tree.orderLaneByID[sourceNodeID] ?? session.source.orderLane,
          session.legalSlots.contains(proposal.slot),
          let moved = try? tree.snapshot.moving(
            sourceNodeID,
            to: proposal.slot,
            scope: persistenceMoveScope(for: session, proposal: proposal)
          )
    else { return nil }

    let sourcePresentationLane = tree.snapshot.sectionID(containing: sourceNodeID).flatMap { $0 }
    if tree.snapshot.isNode(sourceNodeID, at: proposal.slot),
       sourcePresentationLane == proposal.targetLane {
      return nil
    }

    let targetOrderLane: SidebarOrderLane = proposal.slot.parentID?.folderID == nil
      ? proposal.targetLane
      : .normal

    let siblingIDs: [SidebarCollectionNodeID]
    if let parentID = proposal.slot.parentID {
      guard let parent = moved.nodes[parentID] else { return nil }
      siblingIDs = parent.childIDs
    } else {
      guard let section = moved.sections.first(where: {
        $0.id == proposal.slot.sectionID
      }) else { return nil }
      siblingIDs = section.rootIDs
    }
    guard let newIndex = siblingIDs.firstIndex(of: sourceNodeID) else { return nil }
    let targetItems = siblingIDs.compactMap { nodeID in
      nodeID.chatID.flatMap { tree.itemByID[$0] }
    }
    let previousNodeID = newIndex > siblingIDs.startIndex
      ? siblingIDs[siblingIDs.index(before: newIndex)]
      : nil
    let nextIndex = siblingIDs.index(after: newIndex)
    let nextNodeID = nextIndex < siblingIDs.endIndex ? siblingIDs[nextIndex] : nil
    let hasPreviousOrder = previousNodeID != nil
    let previousOrder = previousNodeID.flatMap {
      tree.trailingPersistedOrder(for: $0, lane: targetOrderLane)
    }
    let hasNextOrder = nextNodeID != nil
    let nextOrder = nextNodeID.flatMap {
      tree.persistedOrder(for: $0, lane: targetOrderLane)
    }

    if case let .folder(folder) = session.source {
      guard proposal.slot.parentID == nil,
            session.reorderPolicy.allowsFolderMove(
              changesSection: sourceLane != proposal.targetLane,
              reordersStableNormalLane: sourceLane == .normal
                && proposal.targetLane == .normal
            )
      else { return nil }
      return .folder(SidebarCollectionFolderMove(
        folder: folder.folder,
        newIndex: newIndex,
        hasPreviousOrder: hasPreviousOrder,
        previousOrder: previousOrder,
        hasNextOrder: hasNextOrder,
        nextOrder: nextOrder,
        sourceLane: sourceLane,
        targetLane: proposal.targetLane
      ))
    }

    guard case let .chat(source) = session.source else { return nil }

    let currentParentID = tree.snapshot.parentID(of: sourceNodeID)
    let hierarchyChange: SidebarCollectionMove.HierarchyChange?
    if case let .chat(destinationParentID)? = proposal.slot.parentID,
       currentParentID != proposal.slot.parentID,
       source.semanticParentID == destinationParentID {
      hierarchyChange = .attach(source.id, parentID: destinationParentID)
    } else if case .chat? = currentParentID, proposal.slot.parentID == nil {
      hierarchyChange = .detach(source.id)
    } else {
      hierarchyChange = nil
    }
    let dialogDestination: DialogOrderDestination? = switch (
      currentParentID?.folderID,
      proposal.slot.parentID?.folderID
    ) {
    case let (current, destination?) where current != destination:
      .folder(destination)
    case (_?, nil):
      .root
    default:
      nil
    }

    let entersPinnedContainer = session.reorderPolicy == .pinningOnly
      && proposal.targetLane == .pinned
      && proposal.slot.parentID?.folderID != nil
      && dialogDestination != nil
    guard session.reorderPolicy.allowsMove(
      sourceIsRoot: currentParentID == nil,
      changesSection: sourceLane != targetOrderLane,
      changesParent: hierarchyChange != nil || dialogDestination != nil,
      entersPinnedContainer: entersPinnedContainer
    ) else { return nil }

    return .chat(SidebarCollectionMove(
      targetItems: targetItems,
      movedItem: tree.itemByID[source.id] ?? source.item,
      sourceIsRoot: currentParentID == nil,
      newIndex: newIndex,
      hasPreviousOrder: hasPreviousOrder,
      previousOrder: previousOrder,
      hasNextOrder: hasNextOrder,
      nextOrder: nextOrder,
      sourceLane: sourceLane,
      targetLane: targetOrderLane,
      hierarchyChange: hierarchyChange,
      dialogDestination: dialogDestination
    ))
  }

  private func persistenceMoveScope(
    for session: ReorderSession,
    proposal: Proposal
  ) -> SidebarCollectionMoveScope {
    if case .folder = session.source { return .attachedSubtree }
    let targetOrderLane: SidebarOrderLane = proposal.slot.parentID?.folderID == nil
      ? proposal.targetLane
      : .normal
    return session.source.orderLane == targetOrderLane ? .attachedSubtree : .sourceOnly
  }

  // MARK: - Cancellation and autoscroll

  private func installCancellationHooks() {
    removeCancellationHooks()
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53 {
        self?.cancelReorder(animated: true, reason: "escape")
        return nil
      }
      return event
    }
    if let window = collectionView.window {
      resignObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.cancelReorder(animated: false, reason: "window-resigned")
        }
      }
    }
  }

  private func removeCancellationHooks() {
    if let escapeMonitor {
      NSEvent.removeMonitor(escapeMonitor)
      self.escapeMonitor = nil
    }
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
      self.resignObserver = nil
    }
  }

  private func startAutoscroll() {
    stopAutoscroll()
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.autoscrollTick()
      }
    }
    RunLoop.main.add(timer, forMode: .eventTracking)
    RunLoop.main.add(timer, forMode: .common)
    autoscrollTimer = timer
  }

  private func stopAutoscroll() {
    autoscrollTimer?.invalidate()
    autoscrollTimer = nil
  }

  private func autoscrollTick() {
    guard var session = reorderSession, session.isSettling == false else { return }
    let previousDropTargetFolderID = session.proposal?.slot.parentID?.folderID
    resamplePointer(for: &session)
    let visible = scrollView.contentView.bounds
    let edge: CGFloat = 28
    let delta: CGFloat
    if session.pointerInCollection.y < visible.minY + edge {
      delta = -5
    } else if session.pointerInCollection.y > visible.maxY - edge {
      delta = 5
    } else {
      return
    }

    let maximumY = max(layout.collectionViewContentSize.height - visible.height, 0)
    let nextY = min(max(visible.origin.y + delta, 0), maximumY)
    guard abs(nextY - visible.origin.y) > 0.1 else { return }
    scrollView.contentView.scroll(to: CGPoint(x: visible.origin.x, y: nextY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    resamplePointer(for: &session)
    let emptyPinnedVisibilityChanged = updateEmptyPinnedSectionVisibility(
      session: &session
    )
    let proposalChanged = acceptProposal(at: session.pointerInCollection, session: &session)
    reorderSession = session
    let dropTargetFolderID = session.proposal?.slot.parentID?.folderID
    if emptyPinnedVisibilityChanged || proposalChanged {
      updateLayoutForReorder(animated: true)
    }
    let pinInstructionChanged = updatePinDropInstructionDimming(session: &session)
    reorderSession = session
    if emptyPinnedVisibilityChanged || proposalChanged || pinInstructionChanged {
      var rowIDs: Set<SidebarCollectionRow.ID> = [.pinDropGuide]
      if let previousDropTargetFolderID { rowIDs.insert(.folder(previousDropTargetFolderID)) }
      if let dropTargetFolderID { rowIDs.insert(.folder(dropTargetFolderID)) }
      refreshVisibleContent(.rowIDs(rowIDs))
    }
    if proposalChanged {
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    previewPanel.move(
      to: previewFrame(for: session).origin,
      horizontalBleed: previewHorizontalBleed
    )
  }

  private func resamplePointer(for session: inout ReorderSession) {
    let screenPoint = NSEvent.mouseLocation
    guard let window = collectionView.window else { return }
    session.pointerScreenPoint = screenPoint
    session.pointerInCollection = collectionView.convert(
      window.convertPoint(fromScreen: screenPoint),
      from: nil
    )
  }

  // MARK: - Scrolling and visibility

  private func handleScrollRequestIfPossible() {
    guard snapshotApplyInFlight == false,
          disclosureTransition == nil,
          isCompletingDisplayUpdate == false,
          pendingDisplayUpdate == nil,
          reorderSession == nil,
          let request = currentScrollRequest,
          request.token != lastScrollRequestToken,
          let dataSource
    else { return }
    guard let index = dataSource.snapshot().itemIdentifiers.firstIndex(
      of: .chat(request.itemID)
    ) else { return }
    lastScrollRequestToken = request.token
    collectionView.scrollToItems(
      at: [IndexPath(item: index, section: 0)],
      scrollPosition: .centeredVertically
    )
  }

  private func updateUnreadViewportButtons(force: Bool = false) {
    guard reorderSession == nil,
          snapshotApplyInFlight == false,
          disclosureTransition == nil,
          isCompletingDisplayUpdate == false,
          pendingDisplayUpdate == nil,
          let presentation
    else { return }
    let visibleRect = collectionView.visibleRect
    let entries: [SidebarUnreadViewportEntry<SidebarCollectionNodeID>]
    if let unreadViewportEntries {
      entries = unreadViewportEntries
    } else {
      var nextEntries: [SidebarUnreadViewportEntry<SidebarCollectionNodeID>] = []
      nextEntries.reserveCapacity(presentation.rows.count)
      for (index, row) in presentation.rows.enumerated() {
        guard let nodeID = row.projectedNodeID,
              let attributes = layout.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
              ),
              attributes.alpha > 0.01,
              attributes.frame.height > 0
        else { continue }
        nextEntries.append(SidebarUnreadViewportEntry(
          id: nodeID,
          minimumY: Double(attributes.frame.minY),
          maximumY: Double(attributes.frame.maxY),
          prominentUnreadCount: row.projectedItem.map {
            $0.item.unread && $0.item.prominentUnreadDot ? 1 : 0
          } ?? row.projectedFolder.map {
            $0.isExpanded ? 0 : $0.prominentUnreadCount
          } ?? 0
        ))
      }
      unreadViewportEntries = nextEntries
      entries = nextEntries
    }
    let state = SidebarUnreadViewportResolver.resolve(
      entries: entries,
      viewportStart: Double(visibleRect.minY),
      viewportLength: Double(visibleRect.height)
    )
    guard force || state != lastUnreadViewportState else { return }
    lastUnreadViewportState = state
    updateUnreadButtonHosts(state)
  }

  private func makeUnreadButtonHost(
    model: SidebarCollectionUnreadButtonModel,
    direction: SidebarUnreadBelowButton.Direction
  ) -> NSHostingView<SidebarCollectionUnreadButtonHost> {
    let host = NSHostingView(rootView: SidebarCollectionUnreadButtonHost(
      model: model,
      direction: direction,
      action: { [weak self] in
        let target = switch direction {
        case .above: self?.lastUnreadViewportState?.above
        case .below: self?.lastUnreadViewportState?.below
        }
        guard let target else { return }
        self?.scrollToUnread(target)
      }
    ))
    host.translatesAutoresizingMaskIntoConstraints = false
    return host
  }

  private func updateUnreadButtonHosts(
    _ state: SidebarUnreadViewportResolution<SidebarCollectionNodeID>
  ) {
    unreadAboveButtonModel.state = state.above
    unreadBelowButtonModel.state = state.below
  }

  private func scrollToUnread(
    _ unread: SidebarUnreadViewportDirection<SidebarCollectionNodeID>
  ) {
    guard let dataSource,
          let rowID = rowID(for: unread.targetID),
          let index = dataSource.snapshot().itemIdentifiers.firstIndex(of: rowID)
    else { return }

    collectionView.layoutSubtreeIfNeeded()
    guard let targetFrame = layout.layoutAttributesForItem(
      at: IndexPath(item: index, section: 0)
    )?.frame else { return }

    let clipView = scrollView.contentView
    let visibleBounds = clipView.bounds
    let plan = SidebarUnreadScrollPlan.resolve(
      currentOffset: Double(visibleBounds.minY),
      targetMinimum: Double(targetFrame.minY),
      targetMaximum: Double(targetFrame.maxY),
      viewportLength: Double(visibleBounds.height),
      contentLength: Double(layout.collectionViewContentSize.height)
    )
    guard abs(plan.targetOffset - Double(visibleBounds.minY)) > 0.5 else { return }

    let targetPoint = NSPoint(
      x: visibleBounds.minX,
      y: CGFloat(plan.targetOffset)
    )
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if reduceMotion {
      clipView.scroll(to: targetPoint)
      scrollView.reflectScrolledClipView(clipView)
      return
    }

    if plan.usesLongDistanceJump {
      clipView.scroll(to: NSPoint(
        x: visibleBounds.minX,
        y: CGFloat(plan.animatedStartOffset)
      ))
      scrollView.reflectScrolledClipView(clipView)
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.28
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      clipView.animator().setBoundsOrigin(targetPoint)
    }
  }

  private func validatePresentationInvariants(context: String) {
#if DEBUG
    guard snapshotApplyInFlight == false,
          disclosureTransition == nil,
          isCompletingDisplayUpdate == false,
          pendingDisplayUpdate == nil,
          let presentation,
          let dataSource
    else { return }

    assert(
      dataSource.snapshot().itemIdentifiers == presentation.orderedIDs,
      "Sidebar snapshot and presentation order diverged at \(context)"
    )
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      guard let indexPath = collectionView.indexPath(for: item),
            let representedRowID = item.representedRowID
      else { continue }
      assert(
        dataSource.itemIdentifier(for: indexPath) == representedRowID,
        "Sidebar item identity diverged at \(context)"
      )
    }
#endif
  }
}

extension SidebarCollectionBodyController: NSCollectionViewDelegateFlowLayout {
  func collectionView(
    _ collectionView: NSCollectionView,
    layout proposedLayout: NSCollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> NSSize {
    let rowID = dataSource?.itemIdentifier(for: indexPath)
    let row = rowID.flatMap { presentation?.rowByID[$0] ?? transitionRowByID[$0] }
    let horizontalInset = proposedLayout === layout
      ? 0
      : Theme.sidebarNativeDefaultEdgeInsets
    return NSSize(
      width: max(collectionView.bounds.width - horizontalInset * 2, 1),
      height: row?.height ?? 44
    )
  }
}
