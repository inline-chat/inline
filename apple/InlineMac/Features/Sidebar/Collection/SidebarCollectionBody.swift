import AppKit
import InlineKit
import InlineMacUI
import Logger
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
  let reorderPolicy: SidebarCollectionReorderPolicy
  let scrollRequest: SidebarCollectionScrollRequest?
  let renderState: SidebarCollectionRenderState
  let content: (SidebarCollectionRow) -> AnyView
  let dragPreviewContent: (SidebarCollectionRow) -> AnyView
  let actions: SidebarCollectionActions

  func makeNSViewController(context _: Context) -> SidebarCollectionBodyController {
    let controller = SidebarCollectionBodyController()
    controller.update(
      input: SidebarCollectionBodyInput(
        rows: rows,
        tree: tree,
        reorderPolicy: reorderPolicy,
        renderState: renderState
      ),
      scrollRequest: scrollRequest,
      content: content,
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
        reorderPolicy: reorderPolicy,
        renderState: renderState
      ),
      scrollRequest: scrollRequest,
      content: content,
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

private struct SidebarCollectionBodyInput {
  let rows: [SidebarCollectionRow]
  let tree: SidebarCollectionTree
  let reorderPolicy: SidebarCollectionReorderPolicy
  let renderState: SidebarCollectionRenderState
}

@MainActor
final class SidebarCollectionBodyController: NSViewController {
  private enum Section {
    case main
  }

  private typealias ModelSlot = SidebarCollectionSlot<
    ChatListItem.Identifier,
    SidebarOrderLane?
  >
  private typealias OptimisticState = SidebarCollectionOptimisticState<
    ChatListItem.Identifier,
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
    let showsEmptyPinnedTarget: Bool
    let hidesPinnedHeader: Bool
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
    let item: SidebarProjectedItem
    let middleY: CGFloat
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
    let source: SidebarProjectedItem
    let tree: SidebarCollectionTree
    let dragGroup: SidebarCollectionDragGroup<ChatListItem.Identifier>
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
    let projectedHitGuides: [ProjectedHitGuide]
    var pinBoundaryY: CGFloat?
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
    let sourceIDs: Set<SidebarCollectionRow.ID>
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

  private enum VisibleRefreshScope {
    case none
    case rowIDs(Set<SidebarCollectionRow.ID>)
    case all
  }

  private let itemIdentifier = NSUserInterfaceItemIdentifier("SidebarCollectionBodyItem")
  private let scrollView = NSScrollView()
  private let collectionView = SidebarExternalDropCollectionView()
  private let layout = SidebarCollectionBodyLayout()
  private let previewPanel = SidebarDragPreviewPanel()
  private let topScrollEdgeView = NSView()
  private let bottomScrollEdgeView = NSView()
  private let log = Log.scoped("SidebarCollectionBody")

  private var dataSource: NSCollectionViewDiffableDataSource<Section, SidebarCollectionRow.ID>?
  private var externalRows: [SidebarCollectionRow] = []
  private var externalTree: SidebarCollectionTree?
  private var presentation: SidebarBodyPresentation?
  private var transitionRowByID: [SidebarCollectionRow.ID: SidebarCollectionRow] = [:]
  private var configuredLayoutDrag: SidebarBodyLayoutDrag?
  private var configuredSettlingSourceIDs: Set<SidebarCollectionRow.ID> = []
  private var reorderPolicy = SidebarCollectionReorderPolicy.manual
  private var latestRenderState: SidebarCollectionRenderState?
  private var nextPresentationGeneration = 0
  private var hasAppliedInitialSnapshot = false
  private var snapshotApplyInFlight = false
  private var isCompletingDisplayUpdate = false
  private var inFlightGeneration: Int?
  private var inFlightViewportAnchor: ViewportAnchor?
  private var inFlightCompletions: [() -> Void] = []
  private var inFlightRefreshScope = VisibleRefreshScope.none
  private var pendingDisplayUpdate: SidebarBodyDisplayUpdate?
  private var content: ((SidebarCollectionRow) -> AnyView)?
  private var dragPreviewContent: ((SidebarCollectionRow) -> AnyView)?
  private var actions: SidebarCollectionActions?
  private var reorderSession: ReorderSession?
  private var pendingMoves: [PendingMove] = []
  private var optimisticState: OptimisticState?
  private var pendingMoveObservationTasks: [UUID: Task<Void, Never>] = [:]
  private var localSettle: LocalSettle?
  private var currentScrollRequest: SidebarCollectionScrollRequest?
  private var lastScrollRequestToken: Int?
  private var lastVisibleChatState: SidebarCollectionVisibleChatState?
  private var boundsObserver: NSObjectProtocol?
  private var frameObserver: NSObjectProtocol?
  private var lastViewportWidth: CGFloat?
  private var scrollEdgeVisibility: SidebarScrollEdgeVisibility?
  private var escapeMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var autoscrollTimer: Timer?
  private var externalDropState = SidebarExternalDropState<
    Int,
    SidebarCollectionExternalDropTarget
  >()

  // MARK: - View lifecycle

  override func loadView() {
    let root = NSView()
    collectionView.collectionViewLayout = layout
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
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: root.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        content: content(row),
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
    stopAutoscroll()
    removeCancellationHooks()
    clearPendingMoves()
    localSettle = nil
    endExternalDrop(sequence: nil)
    reorderSession = nil
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
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    synchronizeCollectionWidthWithViewport()
    collectionView.layoutSubtreeIfNeeded()
    layoutScrollEdgeViews()
    updateScrollEdges(animated: false)
  }

  // MARK: - Viewport geometry

  private func viewportBoundsDidChange() {
    reportVisibleChatIDs()
    updateScrollEdges(animated: true)
  }

  private func viewportFrameDidChange() {
    synchronizeCollectionWidthWithViewport()
    collectionView.layoutSubtreeIfNeeded()
    layoutScrollEdgeViews()
    updateScrollEdges(animated: false)
    reportVisibleChatIDs(force: true)
  }

  private func configureScrollEdgeView(_ edgeView: NSView) {
    edgeView.wantsLayer = true
    edgeView.layer?.backgroundColor = NSColor.secondaryLabelColor
      .withAlphaComponent(0.16)
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
    let contentHeight = layout.collectionViewContentSize.height
    let next = SidebarScrollEdgeVisibility.resolve(
      viewportStart: Double(viewport.minY),
      viewportLength: Double(viewport.height),
      contentLength: Double(contentHeight)
    )
    guard scrollEdgeVisibility != next else { return }
    scrollEdgeVisibility = next

    let shouldAnimate = animated
      && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = shouldAnimate ? 0.14 : 0
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      topScrollEdgeView.animator().alphaValue = next.top ? 1 : 0
      bottomScrollEdgeView.animator().alphaValue = next.bottom ? 1 : 0
    }
  }

  private func synchronizeCollectionWidthWithViewport() {
    let viewportWidth = scrollView.contentView.bounds.width
    guard viewportWidth > 0,
          lastViewportWidth.map({ abs($0 - viewportWidth) > 0.5 }) ?? true
    else { return }

    lastViewportWidth = viewportWidth
    var documentFrame = collectionView.frame
    documentFrame.size.width = viewportWidth
    collectionView.frame = documentFrame
    collectionView.collectionViewLayout?.invalidateLayout()
    collectionView.needsLayout = true
  }

  // MARK: - SwiftUI input and diffable presentation

  fileprivate func update(
    input: SidebarCollectionBodyInput,
    scrollRequest: SidebarCollectionScrollRequest?,
    content: @escaping (SidebarCollectionRow) -> AnyView,
    dragPreviewContent: @escaping (SidebarCollectionRow) -> AnyView,
    actions: SidebarCollectionActions
  ) {
    let inputRows = input.rows
    let rows = rowsWithLatentEmptyPinnedGuide(inputRows)
    let tree = input.tree
    let previousExternalIDs = externalRows.map(\.id)
    externalRows = inputRows
    externalTree = tree
    let reorderPolicyChanged = reorderPolicy != input.reorderPolicy
    reorderPolicy = input.reorderPolicy
    latestRenderState = input.renderState
    self.content = content
    self.dragPreviewContent = dragPreviewContent
    self.actions = actions
    currentScrollRequest = scrollRequest

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
      let latestGroup = try? tree.snapshot.dragGroup(for: session.source.id)
      let sourceParentChanged = tree.snapshot.parentID(of: session.source.id)
        != session.tree.snapshot.parentID(of: session.source.id)
      let sourceSectionChanged = tree.snapshot.sectionID(containing: session.source.id)
        != session.tree.snapshot.sectionID(containing: session.source.id)
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
        animatingDifferences: previousExternalIDs != inputRows.map(\.id)
          || reconciliation?.cancelledMoveIDs.isEmpty == false,
        reason: "optimistic-rebase"
      )
    } else {
      optimisticState = OptimisticState(confirmed: tree.snapshot)
      requestDisplayRows(
        rows,
        animatingDifferences: previousExternalIDs != inputRows.map(\.id)
          || reconciliation?.cancelledMoveIDs.isEmpty == false,
        reason: reconciliation?.acknowledgedMoveIDs.isEmpty == false
          ? "optimistic-acknowledged"
          : "model-update"
      )
    }

    handleScrollRequestIfPossible()
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

    guard dataSource != nil else {
      pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: update)
      return
    }

    if isCompletingDisplayUpdate {
      pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: update)
      return
    }

    if snapshotApplyInFlight {
      if nextPresentation.orderedIDs == presentation?.orderedIDs {
        applyContentUpdateDuringSnapshot(update)
      } else {
        pendingDisplayUpdate = coalescing(pendingDisplayUpdate, with: update)
        log.debug(
          "presentation #\(nextPresentation.generation) queued reason=\(reason) "
            + "rows=\(rows.count)"
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
       dataSource.snapshot().itemIdentifiers == next.orderedIDs {
      applyContentOnlyUpdate(update)
      return
    }

    let previousPresentation = presentation
    let previousRows = previousPresentation?.rowByID ?? [:]
    inFlightViewportAnchor = update.reason == "optimistic-drop"
      ? nil
      : captureViewportAnchor(survivingIn: Set(next.orderedIDs))
    transitionRowByID = previousRows.merging(next.rowByID) { _, latest in latest }
    layout.prepareTransition(from: previousPresentation)
    presentation = next
    configureLayout(for: next)
    inFlightRefreshScope = refreshScope(from: previousPresentation, to: next)

    var snapshot = NSDiffableDataSourceSnapshot<Section, SidebarCollectionRow.ID>()
    snapshot.appendSections([.main])
    snapshot.appendItems(next.orderedIDs, toSection: .main)

    snapshotApplyInFlight = true
    inFlightGeneration = next.generation
    inFlightCompletions.append(contentsOf: update.completions)
    let animate = hasAppliedInitialSnapshot
      && update.animatingDifferences
      && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    log.debug(
      "presentation #\(next.generation) apply reason=\(update.reason) "
        + "rows=\(next.rows.count) animated=\(animate)"
    )

    dataSource.apply(snapshot, animatingDifferences: animate) { [weak self] in
      self?.completeDisplayUpdate(generation: next.generation)
    }
  }

  private func applyContentOnlyUpdate(_ update: SidebarBodyDisplayUpdate) {
    let previousPresentation = presentation
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
    reportVisibleChatIDs(force: true)
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

    snapshotApplyInFlight = false
    inFlightGeneration = nil
    hasAppliedInitialSnapshot = true
    transitionRowByID = presentation?.rowByID ?? [:]
    let refreshScope = inFlightRefreshScope
    inFlightRefreshScope = .none
    refreshVisibleContent(refreshScope)
    collectionView.layoutSubtreeIfNeeded()
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
      reportVisibleChatIDs(force: true)
      handleScrollRequestIfPossible()
    }

    log.debug("presentation #\(generation) complete next=\(nextUpdate != nil)")
  }

  private func performPendingDisplayUpdateIfNeeded() {
    guard snapshotApplyInFlight == false,
          isCompletingDisplayUpdate == false,
          let pendingDisplayUpdate,
          dataSource != nil
    else { return }
    self.pendingDisplayUpdate = nil
    performDisplayUpdate(pendingDisplayUpdate)
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
        content: content(row),
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
      || oldRenderState.preview.themeRevision != newRenderState.preview.themeRevision {
      return .all
    }

    var rowIDs = Set(next.rows.compactMap { row in
      previous.rowByID[row.id] == row ? nil : row.id
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
        || oldRow.projectedItem?.lane != newRow.projectedItem?.lane
    }
  }

  private var currentLayoutDrag: SidebarBodyLayoutDrag? {
    guard let session = reorderSession, let proposal = session.proposal else { return nil }
    let pinnedRootIDs = session.tree.snapshot.sections
      .first(where: { $0.id == .pinned })?
      .rootIDs ?? []
    let showsEmptyPinnedTarget = proposal.targetLane == .pinned
      && pinnedRootIDs.isEmpty
    let hidesPinnedHeader = proposal.targetLane != .pinned
      && pinnedRootIDs == [session.source.id]
    return SidebarBodyLayoutDrag(
      sourceIDs: Set(session.draggedBlockIDs),
      destinationIndex: proposal.destinationIndex,
      // The pointer phase always lifts one immutable visible group. Even when
      // crossing a lane will eventually pin/unpin only the head, narrowing the
      // hole before mouse-up makes the preview and collection disagree and
      // pulls every row below it upward. Resolve that semantic split at drop;
      // never mutate the visible drag payload underneath the cursor.
      slotHeight: session.initialPreviewFrame.height,
      showsEmptyPinnedTarget: showsEmptyPinnedTarget,
      hidesPinnedHeader: hidesPinnedHeader
    )
  }

  private func configureLayout(for presentation: SidebarBodyPresentation) {
    let drag = currentLayoutDrag
    let settlingSourceIDs = localSettle?.sourceIDs ?? []
    configuredLayoutDrag = drag
    configuredSettlingSourceIDs = settlingSourceIDs
    layout.configure(
      presentation: presentation,
      drag: drag,
      settlingSourceIDs: settlingSourceIDs
    )
  }

  private var layoutInteractionConfigurationChanged: Bool {
    configuredLayoutDrag != currentLayoutDrag
      || configuredSettlingSourceIDs != (localSettle?.sourceIDs ?? [])
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
          isCompletingDisplayUpdate == false,
          pendingDisplayUpdate == nil,
          let source = rowForHosting(rowID)?.projectedItem,
          source.orderLane != nil,
          reorderPolicy == .manual || source.parentID == nil,
          let dragGroup = try? tree.snapshot.dragGroup(for: source.id),
          let legalSlots = try? tree.snapshot.legalSlots(for: source.id),
          let window = collectionView.window
    else { return }

    collectionView.layoutSubtreeIfNeeded()
    let rowIDs = displayRows.map(\.id)
    let blockIDs = dragGroup.visibleNodeIDs.map { SidebarCollectionRow.ID.chat($0) }
    let stableFrames: [SidebarCollectionRow.ID: CGRect] = Dictionary(
      uniqueKeysWithValues: rowIDs.enumerated().compactMap { index, id -> (SidebarCollectionRow.ID, CGRect)? in
      guard let frame = layout.layoutAttributesForItem(
        at: IndexPath(item: index, section: 0)
      )?.frame else { return nil }
      return (id, frame)
      }
    )
    let projectedHitGuides = displayRows.compactMap { row -> ProjectedHitGuide? in
      guard let item = row.projectedItem,
            let frame = stableFrames[row.id]
      else { return nil }
      return ProjectedHitGuide(item: item, middleY: frame.midY)
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
      pinBoundaryY: layout.laneBoundaryFrame?.minY,
      reorderPolicy: reorderPolicy,
      originalProposal: nil,
      proposal: nil
    )
    var rootProposals = normalizedProposals(rootProposals(session: session).filter {
      session.legalSlots.contains($0.slot)
    }, session: session)
    if reorderPolicy == .pinningOnly {
      rootProposals = pinningOnlyProposals(
        from: rootProposals,
        session: session
      )
    }
    session.rootProposals = ProposalGroup(rootProposals)
    session.pinnedRootProposals = ProposalGroup(
      rootProposals.filter { $0.targetLane == .pinned }
    )
    session.normalRootProposals = ProposalGroup(
      rootProposals.filter { $0.targetLane == .normal }
    )
    if session.pinBoundaryY == nil {
      session.pinBoundaryY = rootProposals.first(where: { proposal in
        proposal.slot.parentID == nil
          && proposal.slot.sectionID == .pinned
          && proposal.slot.beforeSiblingID == nil
      })?.guideY
    }
    if reorderPolicy == .manual, let parentID = source.semanticParentID {
      session.childProposals = ProposalGroup(
        normalizedProposals(
          childProposals(parentID: parentID, session: session).filter {
            session.legalSlots.contains($0.slot)
          },
          session: session
        )
      )
    }
    session.originalProposal = (
      session.rootProposals.proposals + session.childProposals.proposals
    ).first {
      session.tree.snapshot.isNode(session.source.id, at: $0.slot)
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
    reorderSession = session
    previewPanel.show(
      rows: blockIDs.compactMap { session.rowByID[$0] },
      content: dragPreviewContent,
      horizontalBleed: previewHorizontalBleed,
      ownerWindow: window,
      frame: previewFrame(for: session)
    )
    updateLayoutForReorder(animated: false)
    installCancellationHooks()
    startAutoscroll()
    log.info(
      "drag[\(String(id.uuidString.prefix(6)))] began visibleRows="
        + "\(session.dragGroup.visibleNodeIDs.count) attachedRows="
        + "\(session.dragGroup.attachedNodeIDs.count) "
        + "collapsed=\(source.isExpandable && source.isExpanded == false)"
        + " policy=\(String(describing: reorderPolicy))"
    )
  }

  private func updateReorder(location _: CGPoint, translation _: CGPoint) {
    guard var session = reorderSession, session.isSettling == false else { return }
    // Gesture locations are event-time samples and can lag after a brief main
    // thread stall. Screen cursor state is the authoritative current pointer.
    resamplePointer(for: &session)
    let proposalChanged = acceptProposal(
      at: session.pointerInCollection,
      session: &session
    )
    reorderSession = session

    if proposalChanged {
      updateLayoutForReorder(animated: true)
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

    session.proposal = candidate
    log.debug(
      "drag[\(String(session.id.uuidString.prefix(6)))] proposal accepted "
        + "destination=\(String(describing: candidate.slot))"
    )
    return true
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
        sourceID: session.source.id,
        destination: proposal.slot,
        scope: moveScope(for: session, proposal: proposal)
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

    let scope = moveScope(for: session, proposal: proposal)
    let settleTargetScreenFrame: CGRect
    if scope == .sourceOnly,
       let sourceHeight = session.rowByID[.chat(session.source.id)]?.height {
      // The pointer phase keeps the immutable group-sized hole. At mouse-up,
      // source-only pinning narrows both preview and destination around their
      // shared top edge so the panel never expands into an empty group frame.
      settleTargetScreenFrame = CGRect(
        x: targetScreenFrame.minX,
        y: targetScreenFrame.maxY - sourceHeight,
        width: targetScreenFrame.width,
        height: sourceHeight
      )
    } else {
      settleTargetScreenFrame = targetScreenFrame
    }
    let settlingSourceIDs: Set<SidebarCollectionRow.ID> = scope == .sourceOnly
      ? [.chat(session.source.id)]
      : Set(session.draggedBlockIDs)
    let pending = PendingMove(
      id: session.id,
      sourceID: .chat(session.source.id),
      sourceIDs: settlingSourceIDs,
      targetLane: proposal.targetLane
    )
    removePendingMoves(forSourceID: pending.sourceID)
    pendingMoves.append(pending)
    localSettle = LocalSettle(
      id: session.id,
      sourceIDs: settlingSourceIDs
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
      animatingDifferences: false,
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
    if scope == .sourceOnly,
       let sourceRow = finalRows.first(where: { $0.id == .chat(session.source.id) }),
       let dragPreviewContent {
      previewPanel.showSourceOnly(
        row: sourceRow,
        content: dragPreviewContent,
        horizontalBleed: previewHorizontalBleed,
        width: session.initialPreviewFrame.width
      )
    }
    previewPanel.settle(
      to: settleTargetScreenFrame,
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
    guard let settle = localSettle,
          settle.id == id,
          settle.previewFinished,
          settle.presentationFinished
    else { return }
    localSettle = nil
    finishLocalPresentation()
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
    let projectedItems = tree
      .replacing(snapshot: snapshot)
      .projectedItems(orderLaneOverrides: laneOverrides)
    func chatRows(_ items: [SidebarProjectedItem]) -> [SidebarCollectionRow] {
      items.map { projectedItem in
        SidebarCollectionRow(
          id: .chat(projectedItem.id),
          kind: .chat(projectedItem),
          height: rowHeight
        )
      }
    }
    let pinnedRows = chatRows(projectedItems.filter { $0.lane == .pinned })
    let contentRows = chatRows(projectedItems.filter { $0.lane == .normal })
    let pinnedExpanded = baseRows.first(where: { $0.id == .sectionHeader(.pinned) })?
      .sectionHeader?.isExpanded ?? true
    let contentExpanded = baseRows.first(where: { $0.id == .sectionHeader(.content) })?
      .sectionHeader?.isExpanded ?? true
    var logicalRows: [SidebarCollectionRow] = []
    if pinnedRows.isEmpty == false {
      logicalRows.append(.sectionHeader(.pinned, isExpanded: pinnedExpanded))
      if pinnedExpanded {
        logicalRows.append(contentsOf: pinnedRows)
      }
    } else {
      // Stable latent identities let the layout reveal the empty-Pinned target
      // without changing collection content or rehosting the active row.
      logicalRows.append(.sectionHeader(.pinned, isExpanded: true, height: 0))
      logicalRows.append(.pinDropGuide())
    }
    logicalRows.append(.sectionHeader(.content, isExpanded: contentExpanded))
    if contentExpanded {
      logicalRows.append(contentsOf: contentRows)
    }

    var result: [SidebarCollectionRow] = []
    var insertedLogicalRows = false
    for row in baseRows {
      if row.projectedItem != nil || row.isSectionHeader || row.id == .pinDropGuide {
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
      ?? rows.firstIndex(where: { $0.projectedItem != nil })
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
      reorderSession = nil
      if let latestSnapshot = externalTree?.snapshot {
        _ = reconcileOptimisticState(with: latestSnapshot)
      }
      requestDisplayRows(
        optimisticPresentationRows(),
        animatingDifferences: false,
        reason: "drag-cancelled"
      ) { [weak self] in
        self?.finishLocalPresentation()
      }
    }
    if animated {
      // Return the one hole to the source before the lifted preview settles.
      // Keeping the previous destination open until the preview arrives was a
      // two-step cancellation: destination closed, then source reappeared.
      if let originalProposal = session.originalProposal,
         session.proposal?.slot != originalProposal.slot {
        session.proposal = originalProposal
        session.isSettling = true
        reorderSession = session
        updateLayoutForReorder(animated: true)
        previewPanel.settle(
          to: session.initialPreviewFrame,
          horizontalBleed: previewHorizontalBleed,
          completion: finish
        )
      } else {
        previewPanel.settle(
          to: session.initialPreviewFrame,
          horizontalBleed: previewHorizontalBleed,
          completion: finish
        )
      }
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
    let delta = CGPoint(
      x: session.pointerScreenPoint.x - session.startScreenPoint.x,
      y: session.pointerScreenPoint.y - session.startScreenPoint.y
    )
    return session.initialPreviewFrame.offsetBy(dx: delta.x, dy: delta.y)
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
    if prefersChildDestination(at: point, session: session),
       session.childProposals.isEmpty == false {
      candidates = session.childProposals
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
    let currentLane = session.proposal?.targetLane ?? session.source.orderLane ?? .normal
    let lane: SidebarOrderLane
    switch currentLane {
    case .pinned where point.y <= boundary + 4:
      lane = .pinned
    case .normal where point.y >= boundary - 4:
      lane = .normal
    default:
      lane = point.y < boundary ? .pinned : .normal
    }
    let proposals = lane == .pinned
      ? session.pinnedRootProposals
      : session.normalRootProposals
    return proposals.isEmpty ? session.rootProposals : proposals
  }

  private func prefersChildDestination(
    at point: CGPoint,
    session: ReorderSession
  ) -> Bool {
    guard let parentID = session.source.semanticParentID,
          point.x >= childDropIndentThreshold,
          let target = closestProjectedItem(toY: point.y, session: session)
    else { return false }

    return target.id == parentID
      || target.parentID == parentID
      || target.id == session.source.id
  }

  private var childDropIndentThreshold: CGFloat {
    Theme.sidebarNativeDefaultEdgeInsets + Theme.sidebarItemInnerSpacing + 12
  }

  private func closestProjectedItem(
    toY y: CGFloat,
    session: ReorderSession
  ) -> SidebarProjectedItem? {
    let guides = session.projectedHitGuides
    guard guides.isEmpty == false else { return nil }

    var lower = 0
    var upper = guides.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if guides[middle].middleY < y {
        lower = middle + 1
      } else {
        upper = middle
      }
    }

    return [lower - 1, lower]
      .filter { guides.indices.contains($0) }
      .min { abs(guides[$0].middleY - y) < abs(guides[$1].middleY - y) }
      .map { guides[$0].item }
  }

  private func rootProposals(session: ReorderSession) -> [Proposal] {
    let reducedRows = ReducedRows(
      removing: Set(session.draggedBlockIDs),
      from: session.originalRowIDs
    )
    let roots = reducedRows.ids.compactMap { rowID ->
      (SidebarCollectionRow.ID, SidebarProjectedItem)? in
      guard let item = session.rowByID[rowID]?.projectedItem, item.parentID == nil else {
        return nil
      }
      return (rowID, item)
    }
    let pinned = roots.filter { $0.1.orderLane == .pinned }
    let normal = roots.filter { $0.1.orderLane == .normal }
    var proposals: [Proposal] = []
    let firstGuideY = firstRootGuideY(roots, session: session)

    appendRootProposals(
      roots: pinned,
      lane: .pinned,
      fallbackGuideY: sectionHeaderFrame(.content, session: session)?.minY
        ?? firstGuideY,
      reducedRows: reducedRows,
      session: session,
      to: &proposals
    )
    appendRootProposals(
      roots: normal,
      lane: .normal,
      fallbackGuideY: sectionHeaderFrame(.content, session: session)?.maxY
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
    guard let sourceLane = session.source.orderLane else { return [] }
    let targetLane: SidebarOrderLane = sourceLane == .pinned ? .normal : .pinned
    let sourceProposal = proposals.first { proposal in
      proposal.targetLane == sourceLane
        && session.tree.snapshot.isNode(session.source.id, at: proposal.slot)
    }

    let targetRoots = session.tree.snapshot.sections
      .first(where: { $0.id == targetLane })?
      .rootIDs
      .filter { $0 != session.source.id } ?? []
    let beforeSiblingID = targetRoots.first { targetID in
      groupIsOrderedBefore(
        session.source.id,
        targetID,
        tree: session.tree
      )
    }
    let targetProposal = proposals.first { proposal in
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

    return [sourceProposal, targetProposal].compactMap { $0 }
  }

  private func groupIsOrderedBefore(
    _ lhs: ChatListItem.Identifier,
    _ rhs: ChatListItem.Identifier,
    tree: SidebarCollectionTree
  ) -> Bool {
    let lhsActivity = groupActivity(lhs, tree: tree)
    let rhsActivity = groupActivity(rhs, tree: tree)
    if lhsActivity != rhsActivity {
      return lhsActivity > rhsActivity
    }
    if lhs.rawValue != rhs.rawValue {
      return lhs.rawValue > rhs.rawValue
    }
    return lhs.kind.rawValue > rhs.kind.rawValue
  }

  private func groupActivity(
    _ rootID: ChatListItem.Identifier,
    tree: SidebarCollectionTree
  ) -> Date {
    let group = try? tree.snapshot.dragGroup(for: rootID)
    return group?.attachedNodeIDs.compactMap { tree.itemByID[$0]?.lastActivityAt }.max()
      ?? tree.itemByID[rootID]?.lastActivityAt
      ?? .distantPast
  }

  private func appendRootProposals(
    roots: [(SidebarCollectionRow.ID, SidebarProjectedItem)],
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
          in: reducedRows.ids
        )
      case .normal:
        insertionIndex = emptyLaneInsertionIndex(
          .normal,
          in: reducedRows.ids
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

    for (rowID, item) in roots {
      guard let insertionIndex = reducedRows.indexByID[rowID],
            let frame = subtreeFrame(for: rowID, session: session)
      else { continue }
      proposals.append(makeProposal(
        slot: ModelSlot(sectionID: lane, parentID: nil, beforeSiblingID: item.id),
        insertionIndex: insertionIndex,
        guideY: frame.minY,
        targetLane: lane,
        reducedIDs: reducedRows.ids
      ))
    }

    guard let last = roots.last,
          let lastIndex = reducedRows.indexByID[last.0],
          let frame = subtreeFrame(for: last.0, session: session)
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
    in rowIDs: [SidebarCollectionRow.ID]
  ) -> Int {
    switch lane {
    case .pinned:
      if let pinnedHeader = rowIDs.firstIndex(of: .sectionHeader(.pinned)) {
        return pinnedHeader + 1
      }
      return rowIDs.firstIndex(of: .sectionHeader(.content))
        ?? firstChatIndex(in: rowIDs, rows: displayRows)
    case .normal:
      return rowIDs.firstIndex(of: .sectionHeader(.content)).map { $0 + 1 }
        ?? indexAfterLastChat(in: rowIDs, rows: displayRows)
    }
  }

  private func sectionHeaderFrame(
    _ header: SidebarCollectionRow.SectionHeader,
    session: ReorderSession
  ) -> CGRect? {
    session.stableFrames[.sectionHeader(header)]
  }

  private func childProposals(
    parentID: ChatListItem.Identifier,
    session: ReorderSession
  ) -> [Proposal] {
    let block = Set(session.draggedBlockIDs)
    let reducedIDs = session.originalRowIDs.filter { block.contains($0) == false }
    let reducedIndexByID = Dictionary(
      uniqueKeysWithValues: reducedIDs.enumerated().map { ($0.element, $0.offset) }
    )
    let siblings = reducedIDs.compactMap { rowID -> (SidebarCollectionRow.ID, SidebarProjectedItem)? in
      guard let item = session.rowByID[rowID]?.projectedItem, item.parentID == parentID else {
        return nil
      }
      return (rowID, item)
    }
    var proposals: [Proposal] = []
    let parentRowID = rowID(for: parentID)
    let sectionID = session.tree.snapshot.sectionID(containing: parentID) ?? nil

    for (rowID, item) in siblings {
      guard let index = reducedIndexByID[rowID],
            let frame = session.stableFrames[rowID],
            let targetLane = item.orderLane ?? session.source.orderLane
      else { continue }
      proposals.append(makeProposal(
        slot: ModelSlot(
          sectionID: sectionID,
          parentID: parentID,
          beforeSiblingID: item.id
        ),
        insertionIndex: index,
        guideY: frame.minY,
        targetLane: targetLane,
        reducedIDs: reducedIDs
      ))
    }

    if let last = siblings.last,
       let index = reducedIndexByID[last.0],
       let frame = subtreeFrame(for: last.0, session: session),
       let targetLane = last.1.orderLane ?? session.source.orderLane {
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
        targetLane: targetLane,
        reducedIDs: reducedIDs
      ))
    } else if let parentIndex = reducedIndexByID[parentRowID],
              let parentFrame = session.stableFrames[parentRowID],
              let parent = session.rowByID[parentRowID]?.projectedItem,
              let targetLane = session.source.orderLane ?? parent.orderLane {
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
    session: ReorderSession
  ) -> [Proposal] {
    guard proposals.isEmpty == false else { return [] }
    let pinnedRootIDs = session.tree.snapshot.sections
      .first(where: { $0.id == .pinned })?
      .rootIDs ?? []
    let plannedRows = session.originalRows.map { row in
      let role: SidebarCollectionDragLayoutRowRole
      switch row.id {
      case .sectionHeader(.pinned):
        role = .pinnedHeader
      case .pinDropGuide:
        role = .emptyPinnedGuide
      default:
        role = .ordinary
      }
      return SidebarCollectionDragLayoutRow(
        id: row.id,
        height: Double(row.height),
        role: role
      )
    }
    let sourceIDs = Set(session.draggedBlockIDs)
    let modes = Set(proposals.map { proposal in
      ProposalLayoutMode(
        showsEmptyPinnedTarget: proposal.targetLane == .pinned
          && pinnedRootIDs.isEmpty,
        hidesPinnedHeader: proposal.targetLane != .pinned
          && pinnedRootIDs == [session.source.id]
      )
    })
    let slotPositionsByMode = Dictionary(uniqueKeysWithValues: modes.map { mode in
      (
        mode,
        SidebarCollectionDragLayoutPlanner.slotPositions(
          rows: plannedRows,
          sourceIDs: sourceIDs,
          showsEmptyPinnedTarget: mode.showsEmptyPinnedTarget,
          hidesPinnedHeader: mode.hidesPinnedHeader,
          emptyPinnedHeaderHeight: Double(SidebarCollectionRow.sectionHeaderHeight)
        )
      )
    })

    return proposals.map { proposal in
      let mode = ProposalLayoutMode(
        showsEmptyPinnedTarget: proposal.targetLane == .pinned
          && pinnedRootIDs.isEmpty,
        hidesPinnedHeader: proposal.targetLane != .pinned
          && pinnedRootIDs == [session.source.id]
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

  private func firstRootGuideY(
    _ roots: [(SidebarCollectionRow.ID, SidebarProjectedItem)],
    session: ReorderSession
  ) -> CGFloat {
    roots.first.flatMap { subtreeFrame(for: $0.0, session: session)?.minY }
      ?? frameUnion(for: session.draggedBlockIDs, frames: session.stableFrames)?.minY
      ?? 0
  }

  private func lastRootGuideY(
    _ roots: [(SidebarCollectionRow.ID, SidebarProjectedItem)],
    session: ReorderSession
  ) -> CGFloat {
    roots.last.flatMap { subtreeFrame(for: $0.0, session: session)?.maxY }
      ?? frameUnion(for: session.draggedBlockIDs, frames: session.stableFrames)?.maxY
      ?? 0
  }

  private func subtreeFrame(
    for rowID: SidebarCollectionRow.ID,
    session: ReorderSession
  ) -> CGRect? {
    guard let index = session.indexByRowID[rowID],
          let source = session.rowByID[rowID]?.projectedItem
    else { return nil }
    var frame: CGRect?
    var cursor = index
    while session.originalRowIDs.indices.contains(cursor) {
      let currentID = session.originalRowIDs[cursor]
      if cursor != index {
        guard let item = session.rowByID[currentID]?.projectedItem,
              item.depth > source.depth else { break }
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
      depths: rowIDs.map { rowByID[$0]?.projectedItem?.depth }
    )
  }

  private func firstChatIndex(
    in rowIDs: [SidebarCollectionRow.ID],
    rows: [SidebarCollectionRow]
  ) -> Int {
    let chatRowIDs = Set(rows.lazy.filter { $0.projectedItem != nil }.map(\.id))
    return rowIDs.firstIndex { chatRowIDs.contains($0) }
      ?? rowIDs.firstIndex(where: isTrailingRow) ?? rowIDs.count
  }

  private func indexAfterLastChat(
    in rowIDs: [SidebarCollectionRow.ID],
    rows: [SidebarCollectionRow]
  ) -> Int {
    let chatRowIDs = Set(rows.lazy.filter { $0.projectedItem != nil }.map(\.id))
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

  private func rowID(for id: ChatListItem.Identifier) -> SidebarCollectionRow.ID {
    .chat(id)
  }

  private func collectionMove(
    for session: ReorderSession,
    proposal: Proposal,
    tree: SidebarCollectionTree
  ) -> SidebarCollectionMove? {
    guard let sourceLane = tree.orderLaneByID[session.source.id] ?? session.source.orderLane,
          session.legalSlots.contains(proposal.slot),
          let moved = try? tree.snapshot.moving(
            session.source.id,
            to: proposal.slot,
            scope: moveScope(for: session, proposal: proposal)
          )
    else { return nil }

    if tree.snapshot.isNode(session.source.id, at: proposal.slot),
       sourceLane == proposal.targetLane {
      return nil
    }

    let siblingIDs: [ChatListItem.Identifier]
    if let parentID = proposal.slot.parentID {
      guard let parent = moved.nodes[parentID] else { return nil }
      siblingIDs = parent.childIDs
    } else {
      guard let section = moved.sections.first(where: {
        $0.id == proposal.slot.sectionID
      }) else { return nil }
      siblingIDs = section.rootIDs
    }
    guard let newIndex = siblingIDs.firstIndex(of: session.source.id) else { return nil }
    let targetItems = siblingIDs.compactMap { tree.itemByID[$0] }
    guard targetItems.count == siblingIDs.count else { return nil }

    let currentParentID = tree.snapshot.parentID(of: session.source.id)
    let hierarchyChange: SidebarCollectionMove.HierarchyChange?
    if let destinationParentID = proposal.slot.parentID,
       currentParentID != destinationParentID {
      hierarchyChange = .attach(session.source.id, parentID: destinationParentID)
    } else if proposal.slot.parentID == nil, currentParentID != nil {
      hierarchyChange = .detach(session.source.id)
    } else {
      hierarchyChange = nil
    }

    guard session.reorderPolicy.allowsMove(
      sourceIsRoot: currentParentID == nil,
      changesSection: sourceLane != proposal.targetLane,
      changesParent: hierarchyChange != nil
    ) else { return nil }

    return SidebarCollectionMove(
      targetItems: targetItems,
      movedItem: tree.itemByID[session.source.id] ?? session.source.item,
      sourceIsRoot: currentParentID == nil,
      newIndex: newIndex,
      sourceLane: sourceLane,
      targetLane: proposal.targetLane,
      hierarchyChange: hierarchyChange
    )
  }

  private func moveScope(
    for session: ReorderSession,
    proposal: Proposal
  ) -> SidebarCollectionMoveScope {
    session.source.orderLane == proposal.targetLane ? .attachedSubtree : .sourceOnly
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
    let proposalChanged = acceptProposal(at: session.pointerInCollection, session: &session)
    reorderSession = session
    if proposalChanged {
      updateLayoutForReorder(animated: true)
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
          isCompletingDisplayUpdate == false,
          pendingDisplayUpdate == nil,
          reorderSession == nil,
          let request = currentScrollRequest,
          request.token != lastScrollRequestToken,
          let dataSource
    else { return }
    lastScrollRequestToken = request.token
    guard let index = dataSource.snapshot().itemIdentifiers.firstIndex(
      of: .chat(request.itemID)
    ) else { return }
    collectionView.scrollToItems(
      at: [IndexPath(item: index, section: 0)],
      scrollPosition: .centeredVertically
    )
  }

  private func reportVisibleChatIDs(force: Bool = false) {
    guard reorderSession == nil,
          snapshotApplyInFlight == false,
          isCompletingDisplayUpdate == false,
          pendingDisplayUpdate == nil,
          let presentation
    else { return }
    let visibleRect = collectionView.visibleRect
    var visibleIDs = Set<ChatListItem.Identifier>()
    var lastAbove: (id: ChatListItem.Identifier, maximumY: CGFloat)?
    var firstBelow: (id: ChatListItem.Identifier, minimumY: CGFloat)?
    for (index, row) in presentation.rows.enumerated() {
      guard let id = row.projectedItem?.id,
            let attributes = layout.layoutAttributesForItem(
              at: IndexPath(item: index, section: 0)
            ),
            attributes.alpha > 0.01,
            attributes.frame.height > 0
      else { continue }
      let lastAboveY = lastAbove?.maximumY ?? -CGFloat.greatestFiniteMagnitude
      let firstBelowY = firstBelow?.minimumY ?? CGFloat.greatestFiniteMagnitude
      if attributes.frame.intersects(visibleRect) {
        visibleIDs.insert(id)
      } else if attributes.frame.maxY <= visibleRect.minY,
                lastAboveY < attributes.frame.maxY {
        lastAbove = (id, attributes.frame.maxY)
      } else if attributes.frame.minY >= visibleRect.maxY,
                firstBelowY > attributes.frame.minY {
        firstBelow = (id, attributes.frame.minY)
      }
    }
    let state = SidebarCollectionVisibleChatState(
      visibleIDs: visibleIDs,
      lastIDAboveViewport: lastAbove?.id,
      firstIDBelowViewport: firstBelow?.id
    )
    guard force || state != lastVisibleChatState else { return }
    lastVisibleChatState = state
    Task { @MainActor [weak self] in
      guard let self,
            reorderSession == nil,
            snapshotApplyInFlight == false,
            isCompletingDisplayUpdate == false,
            pendingDisplayUpdate == nil,
            lastVisibleChatState == state
      else { return }
      actions?.visibleChatStateChanged(state)
    }
  }

  private func validatePresentationInvariants(context: String) {
#if DEBUG
    guard snapshotApplyInFlight == false,
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
