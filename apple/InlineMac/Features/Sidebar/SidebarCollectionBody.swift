import AppKit
import InlineKit
import Logger
import QuartzCore
import SwiftUI

/// Inbox-only collection body for the custom sidebar interaction experiment.
///
/// `NSCollectionView` supplies reuse and scrolling. Internal reorder deliberately
/// does not use `NSDraggingSession`, collection-view drop proposals, or native
/// drag imagery. One app-owned drag state drives the lifted preview and layout
/// slot so they cannot disagree.
struct SidebarCollectionBody: NSViewControllerRepresentable {
  let rows: [SidebarCollectionRow]
  let scrollRequest: SidebarCollectionScrollRequest?
  let renderState: SidebarCollectionRenderState
  let content: (SidebarCollectionRow) -> AnyView
  let dragPreviewContent: (SidebarCollectionRow) -> AnyView
  let actions: SidebarCollectionActions

  func makeNSViewController(context _: Context) -> SidebarCollectionBodyController {
    let controller = SidebarCollectionBodyController()
    controller.update(
      rows: rows,
      scrollRequest: scrollRequest,
      renderState: renderState,
      content: content,
      dragPreviewContent: dragPreviewContent,
      actions: actions
    )
    return controller
  }

  func updateNSViewController(_ controller: SidebarCollectionBodyController, context _: Context) {
    controller.update(
      rows: rows,
      scrollRequest: scrollRequest,
      renderState: renderState,
      content: content,
      dragPreviewContent: dragPreviewContent,
      actions: actions
    )
  }
}

private struct SidebarBodyPresentation {
  let generation: Int
  let rows: [SidebarCollectionRow]
  let orderedIDs: [SidebarCollectionRow.ID]
  let rowByID: [SidebarCollectionRow.ID: SidebarCollectionRow]
  let renderState: SidebarCollectionRenderState

  init(
    generation: Int,
    rows: [SidebarCollectionRow],
    renderState: SidebarCollectionRenderState
  ) {
    let orderedIDs = rows.map(\.id)
    precondition(
      Set(orderedIDs).count == orderedIDs.count,
      "Sidebar presentation contains duplicate row identifiers"
    )
    self.generation = generation
    self.rows = rows
    self.orderedIDs = orderedIDs
    rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    self.renderState = renderState
  }
}

private struct SidebarBodyDisplayUpdate {
  let presentation: SidebarBodyPresentation
  let reason: String
  let animatingDifferences: Bool
  var completions: [() -> Void]
}

private struct SidebarBodyLayoutDrag: Equatable {
  let sourceIDs: Set<SidebarCollectionRow.ID>
  let destinationIndex: Int
  let slotHeight: CGFloat
  let targetLane: SidebarOrderLane
}

private final class SidebarCollectionBodyLayout: NSCollectionViewLayout {
  private(set) var slotFrame: CGRect?
  private(set) var laneSeparatorFrame: CGRect?

  private var presentation: SidebarBodyPresentation?
  private var drag: SidebarBodyLayoutDrag?
  private var laneOverrides: [SidebarCollectionRow.ID: SidebarOrderLane] = [:]
  private var itemAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
  private var contentSize = CGSize.zero

  func configure(
    presentation: SidebarBodyPresentation,
    drag: SidebarBodyLayoutDrag?,
    laneOverrides: [SidebarCollectionRow.ID: SidebarOrderLane]
  ) {
    self.presentation = presentation
    self.drag = drag
    self.laneOverrides = laneOverrides
    invalidateLayout()
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
    guard let collectionView else { return true }
    return abs(newBounds.width - collectionView.bounds.width) > 0.5
  }

  override func prepare() {
    super.prepare()
    guard let collectionView else { return }

    let horizontalInset = Theme.sidebarNativeDefaultEdgeInsets
    let collectionWidth = collectionView.bounds.width
    let insetWidth = max(collectionWidth - horizontalInset * 2, 1)
    var attributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    var y: CGFloat = 0
    var reducedIndex = 0
    var insertedSlot = false
    var insertedLaneSeparator = false
    var encounteredPinnedLane = false
    let rows = presentation?.rows ?? []
    let sourceIDs = drag?.sourceIDs ?? []
    let hasPinnedLane = rows.contains { row in
      sourceIDs.contains(row.id) == false && effectiveLane(for: row) == .pinned
    } || drag?.targetLane == .pinned

    func insertLaneSeparatorIfNeeded(before lane: SidebarOrderLane?) {
      guard hasPinnedLane,
            encounteredPinnedLane,
            insertedLaneSeparator == false,
            lane != .pinned
      else { return }

      laneSeparatorFrame = CGRect(
        x: horizontalInset,
        y: y,
        width: insetWidth,
        height: SidebarSeparatorRow.totalHeight
      )
      y += SidebarSeparatorRow.totalHeight
      insertedLaneSeparator = true
    }

    func didInsertElement(in lane: SidebarOrderLane?) {
      if lane == .pinned {
        encounteredPinnedLane = true
      }
    }

    func insertSlotIfNeeded() {
      guard insertedSlot == false,
            let drag,
            reducedIndex == drag.destinationIndex
      else { return }

      insertLaneSeparatorIfNeeded(before: drag.targetLane)
      slotFrame = CGRect(x: 0, y: y, width: collectionWidth, height: drag.slotHeight)
      y += drag.slotHeight
      insertedSlot = true
      didInsertElement(in: drag.targetLane)
    }

    slotFrame = nil
    laneSeparatorFrame = nil
    for (index, row) in rows.enumerated() {
      let indexPath = IndexPath(item: index, section: 0)
      let itemAttributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)

      if drag?.sourceIDs.contains(row.id) == true {
        itemAttributes.frame = itemFrame(
          for: row,
          y: y,
          collectionWidth: collectionWidth,
          horizontalInset: horizontalInset,
          insetWidth: insetWidth
        )
        itemAttributes.alpha = 0
        attributes[indexPath] = itemAttributes
        continue
      }

      insertSlotIfNeeded()
      let lane = effectiveLane(for: row)
      insertLaneSeparatorIfNeeded(before: lane)
      itemAttributes.frame = itemFrame(
        for: row,
        y: y,
        collectionWidth: collectionWidth,
        horizontalInset: horizontalInset,
        insetWidth: insetWidth
      )
      itemAttributes.alpha = 1
      attributes[indexPath] = itemAttributes
      y += row.height
      reducedIndex += 1
      didInsertElement(in: lane)
    }

    insertSlotIfNeeded()
    if let drag, insertedSlot == false {
      insertLaneSeparatorIfNeeded(before: drag.targetLane)
      slotFrame = CGRect(x: 0, y: y, width: collectionWidth, height: drag.slotHeight)
      y += drag.slotHeight
      didInsertElement(in: drag.targetLane)
    }
    if hasPinnedLane, encounteredPinnedLane, insertedLaneSeparator == false {
      laneSeparatorFrame = CGRect(
        x: horizontalInset,
        y: y,
        width: insetWidth,
        height: SidebarSeparatorRow.totalHeight
      )
      y += SidebarSeparatorRow.totalHeight
    }

    itemAttributes = attributes
    contentSize = CGSize(width: collectionView.bounds.width, height: max(y, collectionView.bounds.height))
  }

  override var collectionViewContentSize: NSSize {
    contentSize
  }

  override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
    itemAttributes.values.filter { attributes in
      attributes.alpha == 0 || attributes.frame.intersects(rect)
    }
  }

  override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
    itemAttributes[indexPath]
  }

  private func effectiveLane(for row: SidebarCollectionRow) -> SidebarOrderLane? {
    laneOverrides[row.id] ?? row.projectedItem?.lane
  }

  private func itemFrame(
    for row: SidebarCollectionRow,
    y: CGFloat,
    collectionWidth: CGFloat,
    horizontalInset: CGFloat,
    insetWidth: CGFloat
  ) -> CGRect {
    if row.projectedItem != nil {
      return CGRect(x: 0, y: y, width: collectionWidth, height: row.height)
    }
    return CGRect(x: horizontalInset, y: y, width: insetWidth, height: row.height)
  }
}

private struct SidebarHostedRow: View {
  let rowID: SidebarCollectionRow.ID?
  let content: AnyView

  var body: some View {
    content.id(rowID)
  }

  static var empty: SidebarHostedRow {
    SidebarHostedRow(rowID: nil, content: AnyView(EmptyView()))
  }
}

private final class SidebarCollectionBodyItem: NSCollectionViewItem {
  typealias PanHandler = (
    SidebarCollectionRow.ID,
    NSGestureRecognizer.State,
    CGPoint,
    CGPoint
  ) -> Void

  private var hostingView: NSHostingView<SidebarHostedRow>?
  private(set) var representedRowID: SidebarCollectionRow.ID?
  private var panHandler: PanHandler?

  private lazy var panRecognizer: NSPanGestureRecognizer = {
    let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    recognizer.buttonMask = 0x1
    return recognizer
  }()

  override func loadView() {
    let root = NSView()
    root.wantsLayer = true
    root.addGestureRecognizer(panRecognizer)
    view = root
  }

  func configure(
    row: SidebarCollectionRow,
    content: AnyView,
    panHandler: @escaping PanHandler
  ) {
    let identityChanged = representedRowID != row.id
    representedRowID = row.id
    self.panHandler = panHandler
    panRecognizer.isEnabled = row.projectedItem?.orderLane != nil

    if identityChanged {
      resetLayerPresentation()
    }

    let hostedRow = SidebarHostedRow(rowID: row.id, content: content)

    if let hostingView {
      hostingView.isHidden = false
      hostingView.rootView = hostedRow
      return
    }

    let hostingView = NSHostingView(rootView: hostedRow)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hostingView, positioned: .below, relativeTo: nil)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: view.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    self.hostingView = hostingView
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    representedRowID = nil
    panHandler = nil
    panRecognizer.isEnabled = false
    hostingView?.rootView = .empty
    hostingView?.isHidden = true
    resetLayerPresentation()
  }

  @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
    guard let representedRowID,
          let collectionView = view.enclosingCollectionView
    else { return }
    panHandler?(
      representedRowID,
      recognizer.state,
      recognizer.location(in: collectionView),
      recognizer.translation(in: collectionView)
    )
  }

  private func resetLayerPresentation() {
    view.alphaValue = 1
    guard let layer = view.layer else { return }
    layer.removeAllAnimations()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 1
    layer.transform = CATransform3DIdentity
    CATransaction.commit()
  }
}

private extension NSView {
  var enclosingCollectionView: NSCollectionView? {
    if let collectionView = self as? NSCollectionView {
      return collectionView
    }
    return superview?.enclosingCollectionView
  }
}

@MainActor
private final class SidebarDragPreviewPanel {
  private let panel: NSPanel
  private weak var ownerWindow: NSWindow?
  private var hostingView: NSHostingView<AnyView>?

  init() {
    panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .floating
    panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
  }

  func show(
    rows: [SidebarCollectionRow],
    content: @escaping (SidebarCollectionRow) -> AnyView,
    horizontalBleed: CGFloat,
    ownerWindow: NSWindow,
    frame: CGRect
  ) {
    let panelFrame = frame.insetBy(dx: -horizontalBleed, dy: 0)
    let preview = AnyView(
      VStack(spacing: 0) {
        ForEach(rows) { row in
          content(row)
            .frame(width: frame.width)
            .frame(height: row.height)
        }
      }
      .frame(width: frame.width, height: frame.height, alignment: .top)
      .padding(.horizontal, horizontalBleed)
      .frame(width: panelFrame.width, height: panelFrame.height)
      .environment(\.controlActiveState, .key)
    )
    let hostingView = NSHostingView(rootView: preview)
    hostingView.frame = CGRect(origin: .zero, size: panelFrame.size)
    hostingView.autoresizingMask = [.width, .height]
    hostingView.appearance = ownerWindow.appearance
    panel.appearance = ownerWindow.appearance
    panel.contentView = hostingView
    self.hostingView = hostingView
    self.ownerWindow = ownerWindow
    panel.setFrame(panelFrame, display: true)
    ownerWindow.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
  }

  func move(to origin: CGPoint, horizontalBleed: CGFloat) {
    panel.setFrameOrigin(CGPoint(x: origin.x - horizontalBleed, y: origin.y))
  }

  func settle(
    to frame: CGRect,
    horizontalBleed: CGFloat,
    completion: @escaping @MainActor () -> Void
  ) {
    let panelFrame = frame.insetBy(dx: -horizontalBleed, dy: 0)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.14
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      panel.animator().setFrame(panelFrame, display: true)
    } completionHandler: {
      Task { @MainActor in completion() }
    }
  }

  func hide() {
    panel.orderOut(nil)
    ownerWindow?.removeChildWindow(panel)
    ownerWindow = nil
    hostingView = nil
    panel.contentView = nil
  }
}

@MainActor
final class SidebarCollectionBodyController: NSViewController {
  private enum Section {
    case main
  }

  private enum Destination: Hashable {
    case root(lane: SidebarOrderLane, beforeID: ChatListItem.Identifier?)
    case child(parentID: ChatListItem.Identifier, beforeID: ChatListItem.Identifier?)

    var isChild: Bool {
      if case .child = self { return true }
      return false
    }
  }

  private struct Proposal: Equatable {
    let destination: Destination
    let orderedRowIDs: [SidebarCollectionRow.ID]
    let destinationIndex: Int
    let targetLane: SidebarOrderLane
    let guideY: CGFloat
  }

  private struct ReorderSession {
    let id: UUID
    let source: SidebarProjectedItem
    let originalRows: [SidebarCollectionRow]
    let originalRowIDs: [SidebarCollectionRow.ID]
    let draggedBlockIDs: [SidebarCollectionRow.ID]
    let stableFrames: [SidebarCollectionRow.ID: CGRect]
    let startScreenPoint: CGPoint
    let initialPreviewFrame: CGRect
    var pointerScreenPoint: CGPoint
    var pointerInCollection: CGPoint
    var proposal: Proposal?
    var isSettling = false
  }

  private struct PendingMove {
    let id: UUID
    let sourceID: SidebarCollectionRow.ID
    let sourceIDs: Set<SidebarCollectionRow.ID>
    let destination: Destination
    let targetLane: SidebarOrderLane
  }

  private struct VisiblePresentation {
    let modelFrame: CGRect
    let translationY: CGFloat
  }

  private let itemIdentifier = NSUserInterfaceItemIdentifier("SidebarCollectionBodyItem")
  private let scrollView = NSScrollView()
  private let collectionView = NSCollectionView()
  private let layout = SidebarCollectionBodyLayout()
  private let previewPanel = SidebarDragPreviewPanel()
  private let laneSeparatorView = NSHostingView<AnyView>(
    rootView: AnyView(SidebarSeparatorRow().allowsHitTesting(false))
  )
  private let log = Log.scoped("SidebarCollectionBody")

  private var dataSource: NSCollectionViewDiffableDataSource<Section, SidebarCollectionRow.ID>?
  private var externalRows: [SidebarCollectionRow] = []
  private var presentation: SidebarBodyPresentation?
  private var transitionRowByID: [SidebarCollectionRow.ID: SidebarCollectionRow] = [:]
  private var configuredLayoutDrag: SidebarBodyLayoutDrag?
  private var configuredLaneOverrides: [SidebarCollectionRow.ID: SidebarOrderLane] = [:]
  private var latestRenderState: SidebarCollectionRenderState?
  private var nextPresentationGeneration = 0
  private var hasAppliedInitialSnapshot = false
  private var snapshotApplyInFlight = false
  private var isCompletingDisplayUpdate = false
  private var inFlightGeneration: Int?
  private var inFlightCompletions: [() -> Void] = []
  private var pendingDisplayUpdate: SidebarBodyDisplayUpdate?
  private var content: ((SidebarCollectionRow) -> AnyView)?
  private var dragPreviewContent: ((SidebarCollectionRow) -> AnyView)?
  private var actions: SidebarCollectionActions?
  private var reorderSession: ReorderSession?
  private var pendingMove: PendingMove?
  private var currentScrollRequest: SidebarCollectionScrollRequest?
  private var lastScrollRequestToken: Int?
  private var lastVisibleChatIDs: Set<ChatListItem.Identifier>?
  private var boundsObserver: NSObjectProtocol?
  private var frameObserver: NSObjectProtocol?
  private var lastViewportWidth: CGFloat?
  private var escapeMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var autoscrollTimer: Timer?

  override func loadView() {
    let root = NSView()
    collectionView.collectionViewLayout = layout
    collectionView.backgroundColors = [.clear]
    collectionView.isSelectable = false
    collectionView.register(SidebarCollectionBodyItem.self, forItemWithIdentifier: itemIdentifier)

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
    laneSeparatorView.isHidden = true
    laneSeparatorView.alphaValue = 0
    scrollView.contentView.addSubview(
      laneSeparatorView,
      positioned: .above,
      relativeTo: collectionView
    )
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
        self?.viewportGeometryDidChange()
      }
    }
    frameObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.viewportGeometryDidChange()
      }
    }
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
    updateLaneSeparator(animated: false)
  }

  private func viewportGeometryDidChange() {
    synchronizeCollectionWidthWithViewport()
    collectionView.layoutSubtreeIfNeeded()
    updateLaneSeparator(animated: false)
    reportVisibleChatIDs()
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

  func update(
    rows: [SidebarCollectionRow],
    scrollRequest: SidebarCollectionScrollRequest?,
    renderState: SidebarCollectionRenderState,
    content: @escaping (SidebarCollectionRow) -> AnyView,
    dragPreviewContent: @escaping (SidebarCollectionRow) -> AnyView,
    actions: SidebarCollectionActions
  ) {
    let previousExternalIDs = externalRows.map(\.id)
    externalRows = rows
    latestRenderState = renderState
    self.content = content
    self.dragPreviewContent = dragPreviewContent
    self.actions = actions
    currentScrollRequest = scrollRequest

    if let session = reorderSession {
      if Set(session.originalRowIDs) != Set(rows.map(\.id)) {
        cancelReorder(animated: false, reason: "identity-update")
        pendingMove = nil
      } else {
        let latestRows = Dictionary(
          rows.map { ($0.id, $0) },
          uniquingKeysWith: { first, _ in first }
        )
        let refreshedRows = displayRows.compactMap { latestRows[$0.id] }
        requestDisplayRows(
          refreshedRows,
          animatingDifferences: false,
          reason: "drag-content-update"
        )
      }
    } else if let pendingMove,
              let rebasedRows = applying(pendingMove, to: rows) {
      if rebasedRows.map(\.id) == rows.map(\.id) {
        self.pendingMove = nil
        requestDisplayRows(
          rows,
          animatingDifferences: false,
          reason: "optimistic-acknowledged"
        )
      } else {
        requestDisplayRows(
          rebasedRows,
          animatingDifferences: previousExternalIDs != rows.map(\.id),
          reason: "optimistic-rebase"
        )
      }
    } else {
      requestDisplayRows(
        rows,
        animatingDifferences: previousExternalIDs != rows.map(\.id),
        reason: "model-update"
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

    let previousRows = presentation?.rowByID ?? [:]
    transitionRowByID = previousRows.merging(next.rowByID) { _, latest in latest }
    presentation = next
    configureLayout(for: next)

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
    presentation = update.presentation
    transitionRowByID = update.presentation.rowByID
    if layoutGeometryChanged(from: previousPresentation, to: update.presentation)
      || layoutInteractionConfigurationChanged {
      configureLayout(for: update.presentation)
      collectionView.needsLayout = true
      collectionView.layoutSubtreeIfNeeded()
      updateLaneSeparator(animated: false)
    }
    refreshVisibleContent()
    validatePresentationInvariants(context: "content-update")
    reportVisibleChatIDs()
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
    transitionRowByID.merge(update.presentation.rowByID) { _, latest in latest }
    if layoutGeometryChanged(from: previousPresentation, to: update.presentation)
      || layoutInteractionConfigurationChanged {
      configureLayout(for: update.presentation)
      collectionView.needsLayout = true
      collectionView.layoutSubtreeIfNeeded()
      updateLaneSeparator(animated: false)
    }
    refreshVisibleContent()
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
    refreshVisibleContent()
    collectionView.layoutSubtreeIfNeeded()
    updateLaneSeparator(animated: false)

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
      reportVisibleChatIDs()
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

  private func refreshVisibleContent(
    only rowIDs: Set<SidebarCollectionRow.ID>? = nil
  ) {
    guard let content else { return }
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      guard let rowID = item.representedRowID,
            rowIDs?.contains(rowID) ?? true,
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
    return SidebarBodyLayoutDrag(
      sourceIDs: Set(session.draggedBlockIDs),
      destinationIndex: proposal.destinationIndex,
      slotHeight: session.initialPreviewFrame.height,
      targetLane: proposal.targetLane
    )
  }

  private var currentLaneOverrides: [SidebarCollectionRow.ID: SidebarOrderLane] {
    guard let pendingMove else { return [:] }
    return Dictionary(
      uniqueKeysWithValues: pendingMove.sourceIDs.map { ($0, pendingMove.targetLane) }
    )
  }

  private func configureLayout(for presentation: SidebarBodyPresentation) {
    let drag = currentLayoutDrag
    let laneOverrides = currentLaneOverrides
    configuredLayoutDrag = drag
    configuredLaneOverrides = laneOverrides
    layout.configure(
      presentation: presentation,
      drag: drag,
      laneOverrides: laneOverrides
    )
  }

  private var layoutInteractionConfigurationChanged: Bool {
    configuredLayoutDrag != currentLayoutDrag
      || configuredLaneOverrides != currentLaneOverrides
  }

  private var previewHorizontalBleed: CGFloat {
    0
  }

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

  private func beginReorder(
    rowID: SidebarCollectionRow.ID,
    location: CGPoint,
    translation: CGPoint
  ) {
    guard reorderSession == nil,
          snapshotApplyInFlight == false,
          isCompletingDisplayUpdate == false,
          pendingDisplayUpdate == nil,
          let source = rowForHosting(rowID)?.projectedItem,
          source.orderLane != nil,
          let window = collectionView.window
    else { return }

    collectionView.layoutSubtreeIfNeeded()
    let rowIDs = displayRows.map(\.id)
    let blockIDs = draggedBlockIDs(for: rowID, in: displayRows)
    let stableFrames: [SidebarCollectionRow.ID: CGRect] = Dictionary(
      uniqueKeysWithValues: rowIDs.enumerated().compactMap { index, id -> (SidebarCollectionRow.ID, CGRect)? in
      guard let frame = layout.layoutAttributesForItem(
        at: IndexPath(item: index, section: 0)
      )?.frame else { return nil }
      return (id, frame)
      }
    )
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
    let id = UUID()
    var session = ReorderSession(
      id: id,
      source: source,
      originalRows: displayRows,
      originalRowIDs: rowIDs,
      draggedBlockIDs: blockIDs,
      stableFrames: stableFrames,
      startScreenPoint: startScreenPoint,
      initialPreviewFrame: initialPreviewFrame,
      pointerScreenPoint: currentScreenPoint,
      pointerInCollection: location,
      proposal: nil
    )
    session.proposal = nearestProposal(at: location, session: session)
    reorderSession = session
    previewPanel.show(
      rows: blockIDs.compactMap(rowForHosting),
      content: dragPreviewContent,
      horizontalBleed: previewHorizontalBleed,
      ownerWindow: window,
      frame: previewFrame(for: session)
    )
    updateLayoutForReorder(animated: false)
    installCancellationHooks()
    startAutoscroll()
    log.info(
      "drag[\(String(id.uuidString.prefix(6)))] began rows=\(blockIDs.count) "
        + "collapsed=\(source.isExpandable && source.isExpanded == false)"
    )
  }

  private func updateReorder(location: CGPoint, translation _: CGPoint) {
    guard var session = reorderSession, session.isSettling == false else { return }
    session.pointerInCollection = location
    session.pointerScreenPoint = screenPoint(for: location) ?? NSEvent.mouseLocation
    let candidate = nearestProposal(at: location, session: session)
    let targetChanged = candidate?.destination != session.proposal?.destination

    if targetChanged,
       let candidate,
       shouldAccept(candidate, over: session.proposal, pointerY: location.y) {
      session.proposal = candidate
      reorderSession = session
      updateLayoutForReorder(animated: true)
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    } else {
      reorderSession = session
    }

    previewPanel.move(
      to: previewFrame(for: session).origin,
      horizontalBleed: previewHorizontalBleed
    )
  }

  private func shouldAccept(
    _ candidate: Proposal,
    over current: Proposal?,
    pointerY: CGFloat
  ) -> Bool {
    guard let current, current.destination != candidate.destination else { return true }
    if candidate.destination.isChild != current.destination.isChild {
      return true
    }
    let candidateDistance = abs(pointerY - candidate.guideY)
    let currentDistance = abs(pointerY - current.guideY)
    return candidateDistance + 4 < currentDistance
  }

  private func finishReorder() {
    guard var session = reorderSession, session.isSettling == false else { return }
    guard let proposal = session.proposal,
          let move = collectionMove(for: session, proposal: proposal),
          let slotFrame = layout.slotFrame,
          let targetScreenFrame = collectionView.window?.convertToScreen(
            collectionView.convert(slotFrame, to: nil)
          )
    else {
      cancelReorder(animated: true, reason: "unchanged")
      return
    }

    session.isSettling = true
    reorderSession = session
    stopAutoscroll()
    removeCancellationHooks()

    let pending = PendingMove(
      id: session.id,
      sourceID: .chat(session.source.id),
      sourceIDs: Set(session.draggedBlockIDs),
      destination: proposal.destination,
      targetLane: proposal.targetLane
    )
    pendingMove = pending
    actions?.move(move) { [weak self] success in
      self?.handleMoveCompletion(id: pending.id, success: success)
    }

    log.info(
      "drag[\(String(session.id.uuidString.prefix(6)))] dropped "
        + "destination=\(String(describing: proposal.destination))"
    )
    previewPanel.settle(
      to: targetScreenFrame,
      horizontalBleed: previewHorizontalBleed
    ) { [weak self] in
      self?.completeLocalSettle(id: session.id)
    }
  }

  private func completeLocalSettle(id: UUID) {
    guard reorderSession?.id == id else { return }
    reorderSession = nil

    let finalRows: [SidebarCollectionRow]
    if let pendingMove,
       let movedRows = applying(pendingMove, to: externalRows) {
      finalRows = movedRows
    } else {
      finalRows = externalRows
    }
    requestDisplayRows(
      finalRows,
      animatingDifferences: false,
      reason: "optimistic-drop"
    ) { [weak self] in
      self?.finishLocalPresentation()
    }
    removeCancellationHooks()
    stopAutoscroll()
  }

  private func handleMoveCompletion(id: UUID, success: Bool) {
    guard pendingMove?.id == id else { return }
    if success {
      log.debug("drag[\(String(id.uuidString.prefix(6)))] persistence completed")
      return
    }

    log.warning("drag[\(String(id.uuidString.prefix(6)))] persistence failed; rolling back")
    pendingMove = nil
    if reorderSession?.id == id {
      cancelReorder(animated: false, reason: "persistence-failed")
    } else {
      requestDisplayRows(
        externalRows,
        animatingDifferences: true,
        reason: "optimistic-rollback"
      )
    }
  }

  private func cancelReorder(animated: Bool, reason: String) {
    guard let session = reorderSession else { return }
    stopAutoscroll()
    removeCancellationHooks()

    let finish = { [weak self] in
      guard let self, reorderSession?.id == session.id else { return }
      reorderSession = nil
      requestDisplayRows(
        externalRows,
        animatingDifferences: false,
        reason: "drag-cancelled"
      ) { [weak self] in
        self?.finishLocalPresentation()
      }
    }
    if animated {
      previewPanel.settle(
        to: session.initialPreviewFrame,
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
    updateLaneSeparator(animated: animated)

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

  private func updateLaneSeparator(animated: Bool) {
    let shouldAnimate = animated
      && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    let duration = shouldAnimate ? 0.16 : 0

    guard let separatorFrame = layout.laneSeparatorFrame else {
      guard laneSeparatorView.isHidden == false else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        laneSeparatorView.animator().alphaValue = 0
      } completionHandler: { [weak self] in
        guard let self, layout.laneSeparatorFrame == nil else { return }
        laneSeparatorView.isHidden = true
      }
      return
    }

    let frameInViewport = collectionView.convert(separatorFrame, to: scrollView.contentView)
    if laneSeparatorView.isHidden {
      laneSeparatorView.frame = frameInViewport
      laneSeparatorView.alphaValue = 0
      laneSeparatorView.isHidden = false
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
      laneSeparatorView.animator().frame = frameInViewport
      laneSeparatorView.animator().alphaValue = 1
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
        return (
          rowID,
          VisiblePresentation(modelFrame: item.view.frame, translationY: translationY)
        )
      }
    )
  }

  private func finishLocalPresentation() {
    collectionView.layoutSubtreeIfNeeded()
    updateLaneSeparator(animated: false)
    for item in collectionView.visibleItems() {
      guard let layer = item.view.layer else { continue }
      layer.removeAnimation(forKey: "sidebar-slot-move")
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = CATransform3DIdentity
      CATransaction.commit()
    }
    previewPanel.hide()
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

  private func nearestProposal(at point: CGPoint, session: ReorderSession) -> Proposal? {
    let candidates: [Proposal]
    if prefersChildDestination(at: point, session: session),
       let parentID = session.source.semanticParentID {
      candidates = childProposals(parentID: parentID, session: session)
    } else {
      candidates = rootProposals(session: session)
    }
    return candidates.min { lhs, rhs in
      let lhsDistance = abs(point.y - lhs.guideY)
      let rhsDistance = abs(point.y - rhs.guideY)
      if abs(lhsDistance - rhsDistance) < 0.5 {
        return proposalPriority(lhs, pointerY: point.y) < proposalPriority(rhs, pointerY: point.y)
      }
      return lhsDistance < rhsDistance
    }
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
    session.originalRows.compactMap { row -> (SidebarProjectedItem, CGFloat)? in
      guard let item = row.projectedItem,
            let frame = session.stableFrames[row.id]
      else { return nil }
      return (item, abs(frame.midY - y))
    }
    .min { $0.1 < $1.1 }?
    .0
  }

  private func proposalPriority(_ proposal: Proposal, pointerY: CGFloat) -> Int {
    switch proposal.destination {
    case .root(.pinned, _):
      return pointerY <= proposal.guideY ? 0 : 1
    case .root(.normal, _):
      return 2
    case .child:
      return 0
    }
  }

  private func rootProposals(session: ReorderSession) -> [Proposal] {
    let block = Set(session.draggedBlockIDs)
    let reducedIDs = session.originalRowIDs.filter { block.contains($0) == false }
    let roots = reducedIDs.compactMap { rowID -> (SidebarCollectionRow.ID, SidebarProjectedItem)? in
      guard let item = projectedItem(rowID, rows: session.originalRows), item.parentID == nil else {
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
      // With no pinned rows, keep the ordinary before-first target at the
      // first row edge. Pinning wins only after crossing the separator line.
      fallbackGuideY: firstGuideY - SidebarSeparatorRow.totalHeight,
      reducedIDs: reducedIDs,
      session: session,
      to: &proposals
    )
    appendRootProposals(
      roots: normal,
      lane: .normal,
      fallbackGuideY: lastRootGuideY(roots, session: session),
      reducedIDs: reducedIDs,
      session: session,
      to: &proposals
    )

    if let lastPinned = pinned.last,
       let firstNormal = normal.first,
       let pinnedFrame = subtreeFrame(for: lastPinned.0, session: session),
       let normalFrame = subtreeFrame(for: firstNormal.0, session: session) {
      let boundary = (pinnedFrame.maxY + normalFrame.minY) / 2
      replaceBoundaryGuides(in: &proposals, boundary: boundary)
    }

    return proposals
  }

  private func appendRootProposals(
    roots: [(SidebarCollectionRow.ID, SidebarProjectedItem)],
    lane: SidebarOrderLane,
    fallbackGuideY: CGFloat,
    reducedIDs: [SidebarCollectionRow.ID],
    session: ReorderSession,
    to proposals: inout [Proposal]
  ) {
    if roots.isEmpty {
      let insertionIndex: Int
      switch lane {
      case .pinned:
        insertionIndex = firstChatIndex(in: reducedIDs, rows: session.originalRows)
      case .normal:
        insertionIndex = indexAfterLastChat(in: reducedIDs, rows: session.originalRows)
      }
      proposals.append(makeProposal(
        destination: .root(lane: lane, beforeID: nil),
        insertionIndex: insertionIndex,
        guideY: fallbackGuideY,
        targetLane: lane,
        reducedIDs: reducedIDs,
        blockIDs: session.draggedBlockIDs
      ))
      return
    }

    for (rowID, item) in roots {
      guard let insertionIndex = reducedIDs.firstIndex(of: rowID),
            let frame = subtreeFrame(for: rowID, session: session)
      else { continue }
      proposals.append(makeProposal(
        destination: .root(lane: lane, beforeID: item.id),
        insertionIndex: insertionIndex,
        guideY: frame.minY,
        targetLane: lane,
        reducedIDs: reducedIDs,
        blockIDs: session.draggedBlockIDs
      ))
    }

    guard let last = roots.last,
          let lastIndex = reducedIDs.firstIndex(of: last.0),
          let frame = subtreeFrame(for: last.0, session: session)
    else { return }
    proposals.append(makeProposal(
      destination: .root(lane: lane, beforeID: nil),
      insertionIndex: indexAfterSubtree(
        startingAt: lastIndex,
        depth: last.1.depth,
        in: reducedIDs,
        rows: session.originalRows
      ),
      guideY: frame.maxY,
      targetLane: lane,
      reducedIDs: reducedIDs,
      blockIDs: session.draggedBlockIDs
    ))
  }

  private func replaceBoundaryGuides(in proposals: inout [Proposal], boundary: CGFloat) {
    proposals = proposals.map { proposal in
      switch proposal.destination {
      case .root(.pinned, nil):
        Proposal(
          destination: proposal.destination,
          orderedRowIDs: proposal.orderedRowIDs,
          destinationIndex: proposal.destinationIndex,
          targetLane: proposal.targetLane,
          guideY: boundary - 3
        )
      case let .root(.normal, beforeID) where beforeID != nil:
        Proposal(
          destination: proposal.destination,
          orderedRowIDs: proposal.orderedRowIDs,
          destinationIndex: proposal.destinationIndex,
          targetLane: proposal.targetLane,
          guideY: max(proposal.guideY, boundary + 3)
        )
      default:
        proposal
      }
    }
  }

  private func childProposals(
    parentID: ChatListItem.Identifier,
    session: ReorderSession
  ) -> [Proposal] {
    let block = Set(session.draggedBlockIDs)
    let reducedIDs = session.originalRowIDs.filter { block.contains($0) == false }
    let siblings = reducedIDs.compactMap { rowID -> (SidebarCollectionRow.ID, SidebarProjectedItem)? in
      guard let item = projectedItem(rowID, rows: session.originalRows), item.parentID == parentID else {
        return nil
      }
      return (rowID, item)
    }
    var proposals: [Proposal] = []
    let parentRowID = rowID(for: parentID)

    for (rowID, item) in siblings {
      guard let index = reducedIDs.firstIndex(of: rowID),
            let frame = session.stableFrames[rowID],
            let targetLane = item.orderLane ?? session.source.orderLane
      else { continue }
      proposals.append(makeProposal(
        destination: .child(parentID: parentID, beforeID: item.id),
        insertionIndex: index,
        guideY: frame.minY,
        targetLane: targetLane,
        reducedIDs: reducedIDs,
        blockIDs: session.draggedBlockIDs
      ))
    }

    if let last = siblings.last,
       let index = reducedIDs.firstIndex(of: last.0),
       let frame = session.stableFrames[last.0],
       let targetLane = last.1.orderLane ?? session.source.orderLane {
      proposals.append(makeProposal(
        destination: .child(parentID: parentID, beforeID: nil),
        insertionIndex: index + 1,
        guideY: frame.maxY,
        targetLane: targetLane,
        reducedIDs: reducedIDs,
        blockIDs: session.draggedBlockIDs
      ))
    } else if let parentIndex = reducedIDs.firstIndex(of: parentRowID),
              let parentFrame = session.stableFrames[parentRowID],
              let parent = projectedItem(parentRowID, rows: session.originalRows),
              let targetLane = session.source.orderLane ?? parent.orderLane {
      proposals.append(makeProposal(
        destination: .child(parentID: parentID, beforeID: nil),
        insertionIndex: parentIndex + 1,
        guideY: parentFrame.maxY,
        targetLane: targetLane,
        reducedIDs: reducedIDs,
        blockIDs: session.draggedBlockIDs
      ))
    }
    return proposals
  }

  private func makeProposal(
    destination: Destination,
    insertionIndex: Int,
    guideY: CGFloat,
    targetLane: SidebarOrderLane,
    reducedIDs: [SidebarCollectionRow.ID],
    blockIDs: [SidebarCollectionRow.ID]
  ) -> Proposal {
    let safeIndex = min(max(insertionIndex, 0), reducedIDs.count)
    var ordered = reducedIDs
    ordered.insert(contentsOf: blockIDs, at: safeIndex)
    return Proposal(
      destination: destination,
      orderedRowIDs: ordered,
      destinationIndex: safeIndex,
      targetLane: targetLane,
      guideY: guideY
    )
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
    guard let index = session.originalRowIDs.firstIndex(of: rowID),
          let source = projectedItem(rowID, rows: session.originalRows)
    else { return nil }
    var frame: CGRect?
    var cursor = index
    while session.originalRowIDs.indices.contains(cursor) {
      let currentID = session.originalRowIDs[cursor]
      if cursor != index {
        guard let item = projectedItem(currentID, rows: session.originalRows),
              item.depth > source.depth else { break }
      }
      if let currentFrame = session.stableFrames[currentID] {
        frame = frame.map { $0.union(currentFrame) } ?? currentFrame
      }
      cursor += 1
    }
    return frame
  }

  private func draggedBlockIDs(
    for sourceID: SidebarCollectionRow.ID,
    in rows: [SidebarCollectionRow]
  ) -> [SidebarCollectionRow.ID] {
    guard let index = rows.firstIndex(where: { $0.id == sourceID }),
          let source = rows[index].projectedItem else { return [sourceID] }
    var result = [sourceID]
    var cursor = index + 1
    while rows.indices.contains(cursor) {
      guard let item = rows[cursor].projectedItem, item.depth > source.depth else { break }
      result.append(rows[cursor].id)
      cursor += 1
    }
    return result
  }

  private func indexAfterSubtree(
    startingAt start: Int,
    depth: Int,
    in rowIDs: [SidebarCollectionRow.ID],
    rows: [SidebarCollectionRow]
  ) -> Int {
    var cursor = start + 1
    while rowIDs.indices.contains(cursor) {
      guard let item = projectedItem(rowIDs[cursor], rows: rows), item.depth > depth else { break }
      cursor += 1
    }
    return cursor
  }

  private func firstChatIndex(
    in rowIDs: [SidebarCollectionRow.ID],
    rows: [SidebarCollectionRow]
  ) -> Int {
    rowIDs.firstIndex { projectedItem($0, rows: rows) != nil }
      ?? rowIDs.firstIndex(where: isTrailingRow) ?? rowIDs.count
  }

  private func indexAfterLastChat(
    in rowIDs: [SidebarCollectionRow.ID],
    rows: [SidebarCollectionRow]
  ) -> Int {
    rowIDs.lastIndex { projectedItem($0, rows: rows) != nil }.map { $0 + 1 }
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

  private func projectedItem(
    _ rowID: SidebarCollectionRow.ID,
    rows: [SidebarCollectionRow]
  ) -> SidebarProjectedItem? {
    rows.first(where: { $0.id == rowID })?.projectedItem
  }

  private func rowID(for id: ChatListItem.Identifier) -> SidebarCollectionRow.ID {
    .chat(id)
  }

  private func collectionMove(
    for session: ReorderSession,
    proposal: Proposal
  ) -> SidebarCollectionMove? {
    guard let sourceLane = session.source.orderLane else { return nil }
    let orderedItems = proposal.orderedRowIDs.compactMap {
      projectedItem($0, rows: session.originalRows)
    }
    let siblings: [SidebarProjectedItem]
    let hierarchyChange: SidebarCollectionMove.HierarchyChange?

    switch proposal.destination {
    case let .root(lane, _):
      siblings = orderedItems.filter {
        ($0.parentID == nil && $0.orderLane == lane) || $0.id == session.source.id
      }
      hierarchyChange = session.source.semanticParentID != nil && session.source.parentID != nil
        ? .detach(session.source.id)
        : nil
    case let .child(parentID, _):
      siblings = orderedItems.filter {
        ($0.parentID == parentID && $0.orderLane == proposal.targetLane)
          || $0.id == session.source.id
      }
      hierarchyChange = session.source.parentID == nil
        ? .attach(session.source.id, parentID: parentID)
        : nil
    }

    guard let newIndex = siblings.firstIndex(where: { $0.id == session.source.id }) else {
      return nil
    }
    let originalIDs = originalSiblingIDs(
      for: session,
      destination: proposal.destination,
      targetLane: proposal.targetLane
    )
    if hierarchyChange == nil,
       sourceLane == proposal.targetLane,
       originalIDs == siblings.map(\.id) {
      return nil
    }

    return SidebarCollectionMove(
      targetItems: siblings.map(\.item),
      movedItem: session.source.item,
      newIndex: newIndex,
      sourceLane: sourceLane,
      targetLane: proposal.targetLane,
      hierarchyChange: hierarchyChange
    )
  }

  private func originalSiblingIDs(
    for session: ReorderSession,
    destination: Destination,
    targetLane: SidebarOrderLane
  ) -> [ChatListItem.Identifier] {
    session.originalRows.compactMap { row -> ChatListItem.Identifier? in
      guard let item = row.projectedItem else { return nil }
      switch destination {
      case let .root(lane, _):
        return item.parentID == nil && item.orderLane == lane ? item.id : nil
      case let .child(parentID, _):
        return item.parentID == parentID && item.orderLane == targetLane ? item.id : nil
      }
    }
  }

  private func applying(
    _ pending: PendingMove,
    to rows: [SidebarCollectionRow]
  ) -> [SidebarCollectionRow]? {
    guard let sourceIndex = rows.firstIndex(where: { $0.id == pending.sourceID }) else {
      return nil
    }
    let blockIDs = draggedBlockIDs(for: pending.sourceID, in: rows)
    let block = Set(blockIDs)
    var reduced = rows.filter { block.contains($0.id) == false }
    let insertionIndex: Int

    switch pending.destination {
    case let .root(lane, beforeID):
      if let beforeID,
         let index = reduced.firstIndex(where: { $0.projectedItem?.id == beforeID }) {
        insertionIndex = index
      } else {
        let laneRoots = reduced.enumerated().filter { _, row in
          row.projectedItem?.parentID == nil && row.projectedItem?.orderLane == lane
        }
        if let last = laneRoots.last {
          insertionIndex = indexAfterSubtree(
            startingAt: last.offset,
            depth: last.element.projectedItem?.depth ?? 0,
            in: reduced.map(\.id),
            rows: reduced
          )
        } else if lane == .pinned {
          insertionIndex = firstChatIndex(in: reduced.map(\.id), rows: reduced)
        } else {
          insertionIndex = indexAfterLastChat(in: reduced.map(\.id), rows: reduced)
        }
      }
    case let .child(parentID, beforeID):
      if let beforeID,
         let index = reduced.firstIndex(where: { $0.projectedItem?.id == beforeID }) {
        insertionIndex = index
      } else if let lastChildIndex = reduced.lastIndex(where: {
        $0.projectedItem?.parentID == parentID
      }) {
        insertionIndex = lastChildIndex + 1
      } else if let parentIndex = reduced.firstIndex(where: {
        $0.projectedItem?.id == parentID
      }) {
        insertionIndex = parentIndex + 1
      } else {
        return nil
      }
    }

    let sourceRows = blockIDs.compactMap { id in rows.first(where: { $0.id == id }) }
    reduced.insert(contentsOf: sourceRows, at: min(max(insertionIndex, 0), reduced.count))
    _ = sourceIndex
    return reduced
  }

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
    session.pointerInCollection.y += nextY - visible.origin.y
    session.proposal = nearestProposal(at: session.pointerInCollection, session: session)
    reorderSession = session
    updateLayoutForReorder(animated: true)
  }

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

  private func reportVisibleChatIDs() {
    guard reorderSession == nil,
          snapshotApplyInFlight == false,
          isCompletingDisplayUpdate == false,
          pendingDisplayUpdate == nil
    else { return }
    let visibleRect = collectionView.visibleRect
    let ids: Set<ChatListItem.Identifier> = Set(
      (presentation?.rows ?? []).enumerated().compactMap { index, row in
        guard let id = row.projectedItem?.id,
              let frame = layout.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
              )?.frame,
              frame.intersects(visibleRect)
        else { return nil }
        return id
      }
    )
    guard ids != lastVisibleChatIDs else { return }
    lastVisibleChatIDs = ids
    Task { @MainActor [weak self] in
      guard let self,
            reorderSession == nil,
            snapshotApplyInFlight == false,
            isCompletingDisplayUpdate == false,
            pendingDisplayUpdate == nil,
            lastVisibleChatIDs == ids
      else { return }
      actions?.visibleChatIDsChanged(ids)
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
