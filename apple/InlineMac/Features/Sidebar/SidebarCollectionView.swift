import AppKit
import InlineKit
import InlineMacUI
import Logger
import QuartzCore
import SwiftUI

struct SidebarCollectionRow: Equatable, Identifiable {
  enum ID: Hashable {
    case allChats
    case grid
    case archiveHeader
    case chat(ChatListItem.Identifier)
    case newThread
    case emptyState
  }

  enum Kind: Equatable {
    case allChats
    case grid
    case archiveHeader
    case chat(SidebarProjectedItem, showsTopSeparator: Bool)
    case newThread
    case emptyState
  }

  let id: ID
  let kind: Kind
  let height: CGFloat

  var projectedItem: SidebarProjectedItem? {
    guard case let .chat(projectedItem, _) = kind else { return nil }
    return projectedItem
  }
}

struct SidebarCollectionScrollRequest: Equatable {
  let itemID: ChatListItem.Identifier
  let token: Int
}

struct SidebarCollectionRenderState: Equatable {
  struct Preview: Equatable {
    let itemSize: String
    let unreadBadgeStyle: String
    let colorScheme: String
    let themeRevision: Int
    let temporaryItemID: ChatListItem.Identifier?
  }

  let selectedPeer: Peer?
  let selectedReplyPeer: Peer?
  let allChatsSelected: Bool
  let gridSelectionKey: String
  let titlesDimmed: Bool
  let scopedProminentUnreadCount: Int
  let scopedOtherUnreadCount: Int
  let homeGridAvatarIDs: [Int64]
  let sidebarAsInbox: Bool
  let preview: Preview
}

struct SidebarCollectionMove {
  enum HierarchyChange: Equatable {
    case detach(ChatListItem.Identifier)
    case attach(ChatListItem.Identifier, parentID: ChatListItem.Identifier)
  }

  let targetItems: [SidebarViewModel.Item]
  let movedItem: SidebarViewModel.Item
  let newIndex: Int
  let sourceLane: SidebarOrderLane
  let targetLane: SidebarOrderLane
  let hierarchyChange: HierarchyChange?
}

struct SidebarCollectionActions {
  let visibleChatIDsChanged: (Set<ChatListItem.Identifier>) -> Void
  let move: (
    SidebarCollectionMove,
    @escaping @MainActor @Sendable (Bool) -> Void
  ) -> Void
  let toggleDisclosure: (ChatListItem.Identifier) -> Void
}

struct SidebarCollectionView: NSViewControllerRepresentable {
  let rows: [SidebarCollectionRow]
  let scrollRequest: SidebarCollectionScrollRequest?
  let renderState: SidebarCollectionRenderState
  let content: (SidebarCollectionRow) -> AnyView
  let dragPreviewContent: (SidebarCollectionRow) -> AnyView
  let actions: SidebarCollectionActions

  func makeNSViewController(context _: Context) -> SidebarCollectionViewController {
    let controller = SidebarCollectionViewController()
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

  func updateNSViewController(_ controller: SidebarCollectionViewController, context _: Context) {
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

private final class SidebarCollectionFlowLayout: NSCollectionViewFlowLayout {
  private var insertedIndexPaths = Set<IndexPath>()
  private var deletedIndexPaths = Set<IndexPath>()

  override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
    guard let collectionView else { return true }
    return newBounds.width != collectionView.bounds.width
  }

  override func prepare(forCollectionViewUpdates updateItems: [NSCollectionViewUpdateItem]) {
    super.prepare(forCollectionViewUpdates: updateItems)
    insertedIndexPaths = Set(updateItems.compactMap { update in
      update.updateAction == .insert ? update.indexPathAfterUpdate : nil
    })
    deletedIndexPaths = Set(updateItems.compactMap { update in
      update.updateAction == .delete ? update.indexPathBeforeUpdate : nil
    })
  }

  override func initialLayoutAttributesForAppearingItem(
    at itemIndexPath: IndexPath
  ) -> NSCollectionViewLayoutAttributes? {
    guard let attributes = (
      super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
        ?? layoutAttributesForItem(at: itemIndexPath)
    )?.copy() as? NSCollectionViewLayoutAttributes else { return nil }
    guard insertedIndexPaths.contains(itemIndexPath) else { return attributes }
    attributes.alpha = 0
    attributes.frame.origin.y -= 4
    return attributes
  }

  override func finalLayoutAttributesForDisappearingItem(
    at itemIndexPath: IndexPath
  ) -> NSCollectionViewLayoutAttributes? {
    guard let attributes = (
      super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
        ?? layoutAttributesForItem(at: itemIndexPath)
    )?.copy() as? NSCollectionViewLayoutAttributes else { return nil }
    guard deletedIndexPaths.contains(itemIndexPath) else { return attributes }
    attributes.alpha = 0
    attributes.frame.origin.y -= 4
    return attributes
  }

  override func finalizeCollectionViewUpdates() {
    super.finalizeCollectionViewUpdates()
    insertedIndexPaths.removeAll()
    deletedIndexPaths.removeAll()
  }

}

private final class SidebarHostedCollectionItem: NSCollectionViewItem {
  private var hostingView: NSHostingView<AnyView>?
  private var onToggleDisclosure: (() -> Void)?

  private lazy var disclosureHitButton: NSButton = {
    let button = NSButton(title: "", target: self, action: #selector(toggleDisclosure))
    button.isBordered = false
    button.isTransparent = true
    button.focusRingType = .none
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setAccessibilityElement(false)
    return button
  }()

  override func loadView() {
    view = NSView()
    view.wantsLayer = true
    view.addSubview(disclosureHitButton)
    NSLayoutConstraint.activate([
      disclosureHitButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      disclosureHitButton.topAnchor.constraint(equalTo: view.topAnchor),
      disclosureHitButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      disclosureHitButton.widthAnchor.constraint(equalToConstant: 24),
    ])
  }

  func setContent(
    _ content: AnyView,
    canToggleDisclosure: Bool,
    onToggleDisclosure: @escaping () -> Void
  ) {
    self.onToggleDisclosure = onToggleDisclosure
    disclosureHitButton.isHidden = canToggleDisclosure == false

    if let hostingView {
      hostingView.rootView = content
      return
    }

    let hostingView = NSHostingView(rootView: content)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hostingView)
    view.addSubview(disclosureHitButton, positioned: .above, relativeTo: hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: view.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    self.hostingView = hostingView
  }

  @objc private func toggleDisclosure() {
    onToggleDisclosure?()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    view.alphaValue = 1
    view.layer?.transform = CATransform3DIdentity
    view.layer?.opacity = 1
  }

}

@MainActor
final class SidebarCollectionViewController: NSViewController, NSCollectionViewDelegateFlowLayout {
  private enum Section {
    case main
  }

  private struct DropProposal: Equatable {
    enum Destination: Equatable {
      case root(lane: SidebarOrderLane, beforeID: ChatListItem.Identifier?)
      case child(parentID: ChatListItem.Identifier, beforeID: ChatListItem.Identifier?)
    }

    let destination: Destination
    let orderedRowIDs: [SidebarCollectionRow.ID]
    let indicatorIndex: Int
    let targetLane: SidebarOrderLane
  }

  private struct ReorderSession {
    let traceID: String
    let source: SidebarProjectedItem
    let originalRowIDs: [SidebarCollectionRow.ID]
    let draggedBlockIDs: [SidebarCollectionRow.ID]
    let stableFramesByRowID: [SidebarCollectionRow.ID: CGRect]
    let forwardYSign: CGFloat
    var proposal: DropProposal?
  }

  private struct DisplayUpdate {
    let rows: [SidebarCollectionRow]
    let renderState: SidebarCollectionRenderState
    let reason: String
    let animatingDifferences: Bool?
    let clearsTransientReorder: Bool
  }

  private struct DragPreviewCacheEntry {
    let row: SidebarCollectionRow
    let revision: SidebarCollectionRenderState.Preview
    let width: CGFloat
    let image: NSImage
  }

  private let itemIdentifier = NSUserInterfaceItemIdentifier("SidebarHostedCollectionItem")
  private let reorderPasteboardType = NSPasteboard.PasteboardType("chat.inline.sidebar-reorder")
  private let scrollView = NSScrollView()
  private let collectionView = NSCollectionView()
  private let layout = SidebarCollectionFlowLayout()

  private var dataSource: NSCollectionViewDiffableDataSource<Section, SidebarCollectionRow.ID>?
  private var rows: [SidebarCollectionRow] = []
  private var rowByID: [SidebarCollectionRow.ID: SidebarCollectionRow] = [:]
  private var modelRowByID: [SidebarCollectionRow.ID: SidebarCollectionRow] = [:]
  private var content: ((SidebarCollectionRow) -> AnyView)?
  private var dragPreviewContent: ((SidebarCollectionRow) -> AnyView)?
  private var actions: SidebarCollectionActions?
  private var lastVisibleChatIDs: Set<ChatListItem.Identifier>?
  private var currentScrollRequest: SidebarCollectionScrollRequest?
  private var lastScrollRequestToken: Int?
  private var reorderSession: ReorderSession?
  private var heldRowIDs: [SidebarCollectionRow.ID]?
  private var heldRowsTask: Task<Void, Never>?
  private var latestExternalRows: [SidebarCollectionRow] = []
  private var latestRenderState: SidebarCollectionRenderState?
  private var displayedRenderState: SidebarCollectionRenderState?
  private var dragPreviewCache: [SidebarCollectionRow.ID: DragPreviewCacheEntry] = [:]
  private var pendingDragPreviewRowIDs: [SidebarCollectionRow.ID] = []
  private var dragPreviewRenderTask: Task<Void, Never>?
  private var lastLayoutWidth: CGFloat?
  private var hasAppliedInitialSnapshot = false
  private var snapshotApplyInFlight = false
  private var pendingDisplayUpdate: DisplayUpdate?
  private var snapshotGeneration = 0
  private var externalUpdateGeneration = 0
  private var visibleReportingSuspendedForReorder = false
  private var boundsObserver: NSObjectProtocol?
  private let log = Log.scoped("SidebarCollection")
  private static let optimisticOrderHoldDuration: Duration = .seconds(3)

  override func loadView() {
    let rootView = NSView()

    layout.scrollDirection = .vertical
    layout.minimumLineSpacing = 0
    layout.minimumInteritemSpacing = 0
    // Match the native horizontal content margins that SwiftUI's sidebar List
    // applies outside its zero-inset rows. The existing row views intentionally
    // compensate for those margins when drawing hover and separator backgrounds.
    layout.sectionInset = NSEdgeInsets(
      top: 0,
      left: Theme.sidebarNativeDefaultEdgeInsets,
      bottom: 0,
      right: Theme.sidebarNativeDefaultEdgeInsets
    )

    collectionView.collectionViewLayout = layout
    collectionView.delegate = self
    collectionView.isSelectable = true
    collectionView.allowsEmptySelection = true
    collectionView.backgroundColors = [.clear]
    collectionView.register(SidebarHostedCollectionItem.self, forItemWithIdentifier: itemIdentifier)
    collectionView.registerForDraggedTypes([reorderPasteboardType])
    collectionView.setDraggingSourceOperationMask(.move, forLocal: true)

    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    collectionView.frame = scrollView.contentView.bounds
    collectionView.autoresizingMask = [.width]
    scrollView.documentView = collectionView
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.contentView.postsBoundsChangedNotifications = true

    rootView.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
    ])

    view = rootView

    dataSource = NSCollectionViewDiffableDataSource<Section, SidebarCollectionRow.ID>(
      collectionView: collectionView
    ) { [weak self] collectionView, indexPath, rowID in
      guard let self,
            let row = rowByID[rowID],
            let content,
            let item = collectionView.makeItem(
              withIdentifier: itemIdentifier,
              for: indexPath
            ) as? SidebarHostedCollectionItem
      else { return nil }

      item.setContent(
        content(row),
        canToggleDisclosure: row.projectedItem?.isExpandable == true,
        onToggleDisclosure: { [weak self] in
          guard let id = row.projectedItem?.id else { return }
          self?.actions?.toggleDisclosure(id)
        }
      )
      scheduleDragPreview(for: row.id)
      return item
    }

    boundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if let session = self.reorderSession {
          self.applyTransientReorder(
            session: session,
            orderedRowIDs: session.proposal?.orderedRowIDs ?? session.originalRowIDs,
            animated: false
          )
        }
        self.reportVisibleChatIDs()
      }
    }

    requestDisplayUpdate(
      rows,
      reason: "view-loaded",
      animatingDifferences: false
    )
  }

  deinit {
    heldRowsTask?.cancel()
    dragPreviewRenderTask?.cancel()
    if let boundsObserver {
      NotificationCenter.default.removeObserver(boundsObserver)
    }
  }

  func update(
    rows: [SidebarCollectionRow],
    scrollRequest: SidebarCollectionScrollRequest?,
    renderState: SidebarCollectionRenderState,
    content: @escaping (SidebarCollectionRow) -> AnyView,
    dragPreviewContent: @escaping (SidebarCollectionRow) -> AnyView,
    actions: SidebarCollectionActions
  ) {
    externalUpdateGeneration += 1
    let previousExternalIDs = latestExternalRows.map(\.id)
    let nextExternalIDs = rows.map(\.id)
    latestExternalRows = rows
    latestRenderState = renderState
    modelRowByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.content = content
    self.dragPreviewContent = dragPreviewContent
    self.actions = actions
    currentScrollRequest = scrollRequest

    let sameIdentitySet = Set(previousExternalIDs) == Set(nextExternalIDs)
    log.debug(
      "model update #\(externalUpdateGeneration) rows=\(rows.count) "
        + "orderChanged=\(previousExternalIDs != nextExternalIDs) "
        + "identityChanged=\(!sameIdentitySet) dragActive=\(reorderSession != nil) "
        + "orderHeld=\(heldRowIDs != nil)"
    )

    if let session = reorderSession,
       Set(session.originalRowIDs) != Set(nextExternalIDs) {
      log.warning(
        "native-drag[\(session.traceID)] invalidated by identity-changing model update "
          + "oldRows=\(session.originalRowIDs.count) newRows=\(nextExternalIDs.count)"
      )
      cancelReorderForExternalUpdate()
    }

    let arrangedRows = arrangedRows(from: rows)
    guard isViewLoaded else {
      self.rows = arrangedRows
      rowByID = Dictionary(arrangedRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      return
    }
    requestDisplayUpdate(
      arrangedRows,
      renderState: renderState,
      reason: "model-update",
      animatingDifferences: nil
    )
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    let width = scrollView.contentSize.width
    var collectionFrame = collectionView.frame
    collectionFrame.size.width = width
    collectionView.frame = collectionFrame
    guard lastLayoutWidth != width else { return }
    lastLayoutWidth = width
    dragPreviewCache.removeAll()
    collectionView.collectionViewLayout?.invalidateLayout()
    scheduleVisibleDragPreviews()
  }

  private func requestDisplayUpdate(
    _ nextRows: [SidebarCollectionRow],
    renderState requestedRenderState: SidebarCollectionRenderState? = nil,
    reason: String,
    animatingDifferences: Bool?,
    clearsTransientReorder: Bool = false
  ) {
    guard let renderState = requestedRenderState ?? latestRenderState else {
      rows = nextRows
      rowByID = Dictionary(nextRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      return
    }
    guard dataSource != nil else {
      rows = nextRows
      rowByID = Dictionary(nextRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      return
    }

    let update = DisplayUpdate(
      rows: nextRows,
      renderState: renderState,
      reason: reason,
      animatingDifferences: animatingDifferences,
      clearsTransientReorder: clearsTransientReorder
    )
    guard snapshotApplyInFlight == false else {
      if pendingDisplayUpdate?.clearsTransientReorder == true,
         update.clearsTransientReorder == false {
        pendingDisplayUpdate = DisplayUpdate(
          rows: update.rows,
          renderState: update.renderState,
          reason: update.reason,
          animatingDifferences: update.animatingDifferences,
          clearsTransientReorder: true
        )
      } else {
        pendingDisplayUpdate = update
      }
      log.debug(
        "snapshot queued reason=\(reason) rows=\(nextRows.count) "
          + "dragActive=\(reorderSession != nil)"
      )
      return
    }

    performDisplayUpdate(update)
  }

  private func performDisplayUpdate(_ update: DisplayUpdate) {
    guard let dataSource else { return }

    let previousRows = rows
    let oldRowsByID = rowByID
    let previousRenderState = displayedRenderState
    rows = update.rows
    rowByID = oldRowsByID.merging(
      Dictionary(update.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      uniquingKeysWith: { _, new in new }
    )

    let previousItemIDs = dataSource.snapshot().itemIdentifiers
    let currentItemIDs = rows.map(\.id)
    let previousRowsByID = Dictionary(
      previousRows.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let changedRowIDs = Set(rows.compactMap { row in
      previousRowsByID[row.id] == row ? nil : row.id
    })
    let renderStateChanged = previousRenderState != update.renderState
    let previewStateChanged = previousRenderState?.preview != update.renderState.preview

    if previewStateChanged {
      dragPreviewCache.removeAll()
    } else {
      for rowID in changedRowIDs {
        dragPreviewCache[rowID] = nil
      }
    }

    // Content-only changes (selection, unread state, active-window dimming) do
    // not need a diffable transaction. Updating the existing hosting views keeps
    // SwiftUI state alive and avoids reload crossfades while the pointer moves.
    guard previousItemIDs != currentItemIDs else {
      rowByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      displayedRenderState = update.renderState
      if renderStateChanged || changedRowIDs.isEmpty == false {
        refreshVisibleItems(only: renderStateChanged ? nil : changedRowIDs)
      }
      let heightsChanged = rows.contains { row in
        previousRowsByID[row.id]?.height != row.height
      }
      if heightsChanged {
        collectionView.collectionViewLayout?.invalidateLayout()
      }
      if update.clearsTransientReorder {
        clearTransientReorder(animated: false)
      }
      scheduleVisibleDragPreviews()
      handleScrollRequest(currentScrollRequest)
      resumeVisibleReportingIfReorderSettled()
      reportVisibleChatIDs()
      performPendingDisplayUpdateIfNeeded()
      return
    }

    var snapshot = NSDiffableDataSourceSnapshot<Section, SidebarCollectionRow.ID>()
    snapshot.appendSections([.main])
    snapshot.appendItems(currentItemIDs, toSection: .main)

    let animate = update.animatingDifferences
      ?? (hasAppliedInitialSnapshot && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    snapshotGeneration += 1
    let generation = snapshotGeneration
    snapshotApplyInFlight = true
    log.debug(
      "snapshot #\(generation) apply reason=\(update.reason) "
        + "oldRows=\(previousItemIDs.count) newRows=\(currentItemIDs.count) animated=\(animate)"
    )
    let completion = { [weak self] in
      guard let self else { return }
      snapshotApplyInFlight = false
      hasAppliedInitialSnapshot = true
      displayedRenderState = update.renderState
      rowByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      refreshVisibleItems()
      if update.clearsTransientReorder {
        clearTransientReorder(animated: false)
      }
      scheduleVisibleDragPreviews()
      handleScrollRequest(currentScrollRequest)
      resumeVisibleReportingIfReorderSettled()
      reportVisibleChatIDs()
      log.debug(
        "snapshot #\(generation) complete displayedRows=\(rows.count) "
          + "pending=\(pendingDisplayUpdate != nil)"
      )
      performPendingDisplayUpdateIfNeeded()
    }
    if animate {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dataSource.apply(snapshot, animatingDifferences: true, completion: completion)
      }
    } else {
      dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
    }
  }

  private func performPendingDisplayUpdateIfNeeded() {
    guard snapshotApplyInFlight == false, let pendingDisplayUpdate else { return }
    self.pendingDisplayUpdate = nil
    performDisplayUpdate(pendingDisplayUpdate)
  }

  private func resumeVisibleReportingIfReorderSettled() {
    guard reorderSession == nil,
          pendingDisplayUpdate == nil,
          snapshotApplyInFlight == false
    else { return }
    visibleReportingSuspendedForReorder = false
  }

  func collectionView(
    _ collectionView: NSCollectionView,
    layout _: NSCollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> NSSize {
    guard rows.indices.contains(indexPath.item) else { return .zero }
    let horizontalInsets = Theme.sidebarNativeDefaultEdgeInsets * 2
    return NSSize(
      width: max(collectionView.bounds.width - horizontalInsets, 1),
      height: rows[indexPath.item].height
    )
  }

  func collectionView(
    _: NSCollectionView,
    canDragItemsAt indexPaths: Set<IndexPath>,
    with _: NSEvent
  ) -> Bool {
    guard indexPaths.count == 1,
          let indexPath = indexPaths.first,
          rows.indices.contains(indexPath.item),
          rows[indexPath.item].projectedItem?.orderLane != nil
    else { return false }
    return true
  }

  func collectionView(
    _: NSCollectionView,
    pasteboardWriterForItemAt indexPath: IndexPath
  ) -> (any NSPasteboardWriting)? {
    guard rows.indices.contains(indexPath.item),
          let projectedItem = rows[indexPath.item].projectedItem,
          projectedItem.orderLane != nil
    else { return nil }

    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(String(projectedItem.id.rawValue), forType: reorderPasteboardType)
    return pasteboardItem
  }

  func collectionView(
    _: NSCollectionView,
    draggingSession: NSDraggingSession,
    willBeginAt _: NSPoint,
    forItemsAt indexPaths: Set<IndexPath>
  ) {
    guard let indexPath = indexPaths.first,
          rows.indices.contains(indexPath.item),
          let source = rows[indexPath.item].projectedItem,
          let sourceLane = source.orderLane
    else { return }

    let rowIDs = rows.map(\.id)
    let sourceRowID = rows[indexPath.item].id
    let draggedBlockIDs = draggedBlockIDs(for: sourceRowID, in: rowIDs)
    let stableFramesByRowID = stableFrames(for: rowIDs)
    let forwardYSign = verticalOrderSign(rowIDs: rowIDs, frames: stableFramesByRowID)
    let traceID = String(UUID().uuidString.prefix(6))
    reorderSession = ReorderSession(
      traceID: traceID,
      source: source,
      originalRowIDs: rowIDs,
      draggedBlockIDs: draggedBlockIDs,
      stableFramesByRowID: stableFramesByRowID,
      forwardYSign: forwardYSign,
      proposal: nil
    )
    visibleReportingSuspendedForReorder = true
    draggingSession.draggingFormation = .none
    draggingSession.animatesToStartingPositionsOnCancelOrFail = true
    installGroupDragPreview(
      source: source,
      for: draggedBlockIDs,
      in: draggingSession
    )
    if let session = reorderSession {
      applyTransientReorder(session: session, orderedRowIDs: rowIDs, animated: false)
    }

    log.info(
      "native-drag[\(traceID)] began sourceIndex=\(indexPath.item) depth=\(source.depth) "
        + "orderLane=\(sourceLane.rawValue) presentationLane=\(source.lane?.rawValue ?? "none") "
        + "blockRows=\(draggedBlockIDs.count) totalRows=\(rowIDs.count) "
        + "forwardYSign=\(forwardYSign)"
    )
  }

  private func installGroupDragPreview(
    source: SidebarProjectedItem,
    for rowIDs: [SidebarCollectionRow.ID],
    in draggingSession: NSDraggingSession
  ) {
    let visibleRowIDSet = Set(collectionView.indexPathsForVisibleItems().compactMap { indexPath in
      rows.indices.contains(indexPath.item) ? rows[indexPath.item].id : nil
    })
    let visibleRowIDs = rowIDs.filter(visibleRowIDSet.contains)
    let previewRowIDs = visibleRowIDs.isEmpty ? Array(rowIDs.prefix(1)) : visibleRowIDs

    guard let groupFrame = frameUnion(for: previewRowIDs) else { return }
    let hiddenReplyCount = rowIDs.count == 1
      ? source.childCount
      : max(rowIDs.count - previewRowIDs.count, 0)
    guard let preview = makeGroupDragPreview(
      rowIDs: previewRowIDs,
      groupFrame: groupFrame,
      hiddenReplyCount: hiddenReplyCount
    ) else { return }

    draggingSession.enumerateDraggingItems(
      options: [],
      for: collectionView,
      classes: [NSPasteboardItem.self],
      searchOptions: [:]
    ) { draggingItem, _, _ in
      draggingItem.setDraggingFrame(preview.frame, contents: preview.image)
    }
  }

  private func makeGroupDragPreview(
    rowIDs: [SidebarCollectionRow.ID],
    groupFrame: CGRect,
    hiddenReplyCount: Int
  ) -> (frame: CGRect, image: NSImage)? {
    let rowWidth = groupFrame.width
    let renderedRows = rowIDs.compactMap { dragPreviewImage($0, width: rowWidth) }
    guard renderedRows.isEmpty == false else { return nil }

    let outerPadding: CGFloat = 7
    let summaryHeight: CGFloat = hiddenReplyCount > 0 ? 20 : 0
    let rowsHeight = renderedRows.reduce(CGFloat.zero) { $0 + $1.size.height }
    let imageSize = CGSize(
      width: rowWidth + outerPadding * 2,
      height: rowsHeight + summaryHeight + outerPadding * 2
    )
    let image = NSImage(size: imageSize)
    image.lockFocus()

    let bounds = CGRect(origin: .zero, size: imageSize)
    let containerRect = bounds.insetBy(dx: outerPadding, dy: outerPadding)
    let containerPath = NSBezierPath(roundedRect: containerRect, xRadius: 9, yRadius: 9)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 8
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    NSColor.controlBackgroundColor.withAlphaComponent(0.97).setFill()
    containerPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    containerPath.addClip()
    var rowY = containerRect.maxY
    for renderedRow in renderedRows {
      rowY -= renderedRow.size.height
      renderedRow.draw(
        in: CGRect(
          x: containerRect.minX,
          y: rowY,
          width: rowWidth,
          height: renderedRow.size.height
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
      )
    }
    NSGraphicsContext.restoreGraphicsState()

    if hiddenReplyCount > 0 {
      drawHiddenReplySummary(
        count: hiddenReplyCount,
        in: CGRect(
          x: containerRect.minX,
          y: containerRect.minY,
          width: containerRect.width,
          height: summaryHeight
        )
      )
    }

    NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
    containerPath.lineWidth = 0.5
    containerPath.stroke()
    image.unlockFocus()

    let frame = CGRect(
      x: groupFrame.minX - outerPadding,
      y: groupFrame.minY - outerPadding,
      width: imageSize.width,
      height: imageSize.height
    )
    return (frame, image)
  }

  private func dragPreviewImage(
    _ rowID: SidebarCollectionRow.ID,
    width: CGFloat
  ) -> NSImage? {
    guard let row = modelRowByID[rowID], let revision = latestRenderState?.preview else {
      return nil
    }
    if let entry = dragPreviewCache[rowID],
       entry.row == row,
       entry.revision == revision,
       entry.width == width {
      return entry.image
    }

    scheduleDragPreview(for: rowID)
    return visibleRowSnapshot(rowID)
  }

  private func renderDragPreviewRowImmediately(
    _ rowID: SidebarCollectionRow.ID,
    width: CGFloat
  ) -> NSImage? {
    guard let row = modelRowByID[rowID], let dragPreviewContent else { return nil }
    let height: CGFloat
    if case let .chat(_, showsTopSeparator) = row.kind, showsTopSeparator {
      height = max(row.height - SidebarSeparatorRow.totalHeight, 1)
    } else {
      height = row.height
    }
    let hostingView = NSHostingView(rootView: dragPreviewContent(row))
    hostingView.appearance = collectionView.effectiveAppearance
    hostingView.frame = CGRect(x: 0, y: 0, width: width, height: height)
    hostingView.layoutSubtreeIfNeeded()
    guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
      return nil
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
    let image = NSImage(size: hostingView.bounds.size)
    image.addRepresentation(representation)
    return image
  }

  private func visibleRowSnapshot(_ rowID: SidebarCollectionRow.ID) -> NSImage? {
    guard let index = rows.firstIndex(where: { $0.id == rowID }),
          let item = collectionView.item(at: IndexPath(item: index, section: 0))
    else { return nil }
    let sourceView = item.view
    sourceView.layoutSubtreeIfNeeded()
    guard let representation = sourceView.bitmapImageRepForCachingDisplay(in: sourceView.bounds) else {
      return nil
    }
    sourceView.cacheDisplay(in: sourceView.bounds, to: representation)
    let image = NSImage(size: sourceView.bounds.size)
    image.addRepresentation(representation)
    return image
  }

  private func scheduleVisibleDragPreviews() {
    for indexPath in collectionView.indexPathsForVisibleItems() where rows.indices.contains(indexPath.item) {
      scheduleDragPreview(for: rows[indexPath.item].id)
    }
    startDragPreviewRendererIfNeeded()
  }

  private func scheduleDragPreview(for rowID: SidebarCollectionRow.ID) {
    guard let row = modelRowByID[rowID], row.projectedItem != nil,
          let revision = latestRenderState?.preview
    else { return }
    let width = max(
      collectionView.bounds.width - Theme.sidebarNativeDefaultEdgeInsets * 2,
      1
    )
    if let entry = dragPreviewCache[rowID],
       entry.row == row,
       entry.revision == revision,
       entry.width == width {
      return
    }
    guard pendingDragPreviewRowIDs.contains(rowID) == false else { return }
    pendingDragPreviewRowIDs.append(rowID)
    startDragPreviewRendererIfNeeded()
  }

  private func startDragPreviewRendererIfNeeded() {
    guard dragPreviewRenderTask == nil, pendingDragPreviewRowIDs.isEmpty == false else { return }
    dragPreviewRenderTask = Task { @MainActor [weak self] in
      while let self, pendingDragPreviewRowIDs.isEmpty == false {
        await Task.yield()
        guard Task.isCancelled == false else { return }
        guard reorderSession == nil else {
          dragPreviewRenderTask = nil
          return
        }

        let rowID = pendingDragPreviewRowIDs.removeFirst()
        guard let row = modelRowByID[rowID], row.projectedItem != nil,
              let revision = latestRenderState?.preview
        else { continue }
        let width = max(
          collectionView.bounds.width - Theme.sidebarNativeDefaultEdgeInsets * 2,
          1
        )
        guard let image = renderDragPreviewRowImmediately(rowID, width: width) else { continue }
        dragPreviewCache[rowID] = DragPreviewCacheEntry(
          row: row,
          revision: revision,
          width: width,
          image: image
        )
      }
      self?.dragPreviewRenderTask = nil
    }
  }

  private func drawHiddenReplySummary(count: Int, in rect: CGRect) {
    let label = count == 1 ? "1 more reply" : "\(count) more replies"
    (label as NSString).draw(
      in: rect.insetBy(dx: Theme.sidebarItemInnerSpacing + 16, dy: 3),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
  }

  private func frameUnion(for rowIDs: [SidebarCollectionRow.ID]) -> CGRect? {
    rowIDs.reduce(into: CGRect?.none) { result, rowID in
      guard let index = rows.firstIndex(where: { $0.id == rowID }),
            let frame = collectionView.collectionViewLayout?
              .layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
      else { return }
      result = result.map { $0.union(frame) } ?? frame
    }
  }

  private func stableFrames(
    for rowIDs: [SidebarCollectionRow.ID]
  ) -> [SidebarCollectionRow.ID: CGRect] {
    Dictionary(uniqueKeysWithValues: rowIDs.enumerated().compactMap { index, rowID in
      guard let frame = collectionView.collectionViewLayout?
        .layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
      else { return nil }
      return (rowID, frame)
    })
  }

  private func verticalOrderSign(
    rowIDs: [SidebarCollectionRow.ID],
    frames: [SidebarCollectionRow.ID: CGRect]
  ) -> CGFloat {
    let midpoints = rowIDs.compactMap { frames[$0]?.midY }
    for (first, second) in zip(midpoints, midpoints.dropFirst())
      where abs(second - first) > 0.5 {
      return second > first ? 1 : -1
    }
    return collectionView.isFlipped ? 1 : -1
  }

  func collectionView(
    _: NSCollectionView,
    draggingSession _: NSDraggingSession,
    endedAt _: NSPoint,
    dragOperation operation: NSDragOperation
  ) {
    guard let session = reorderSession else { return }
    log.info(
      "native-drag[\(session.traceID)] ended operation=\(operation.rawValue) accepted=false"
    )
    clearTransientReorder(animated: true)
    reorderSession = nil
    resumeVisibleReportingIfReorderSettled()
    requestDisplayUpdate(latestExternalRows, reason: "native-drag-ended", animatingDifferences: false)
  }

  private func projectedItem(for rowID: SidebarCollectionRow.ID?) -> SidebarProjectedItem? {
    guard let rowID else { return nil }
    return modelRowByID[rowID]?.projectedItem
  }

  func collectionView(
    _: NSCollectionView,
    validateDrop draggingInfo: any NSDraggingInfo,
    proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
    dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
  ) -> NSDragOperation {
    guard draggingInfo.draggingPasteboard.availableType(from: [reorderPasteboardType]) != nil,
          let indicatorIndex = updateNativeReorder(
            at: collectionView.convert(draggingInfo.draggingLocation, from: nil)
          )
    else { return [] }

    proposedDropIndexPath.pointee = NSIndexPath(forItem: indicatorIndex, inSection: 0)
    proposedDropOperation.pointee = .before
    draggingInfo.animatesToDestination = true
    draggingInfo.numberOfValidItemsForDrop = 1
    return .move
  }

  func collectionView(
    _: NSCollectionView,
    acceptDrop _: any NSDraggingInfo,
    indexPath _: IndexPath,
    dropOperation _: NSCollectionView.DropOperation
  ) -> Bool {
    guard let session = reorderSession,
          let sourceLane = session.source.orderLane,
          let proposal = session.proposal
    else { return false }

    let move = collectionMove(for: session, proposal: proposal, sourceLane: sourceLane)
    let finalRowIDs = move == nil ? session.originalRowIDs : proposal.orderedRowIDs

    log.info(
      "native-drag[\(session.traceID)] accepted moved=\(move != nil) "
        + "sourceLane=\(sourceLane.rawValue) targetLane=\(proposal.targetLane.rawValue) "
        + "destination=\(String(describing: proposal.destination))"
    )
    reorderSession = nil
    if move != nil {
      holdVisualOrder(finalRowIDs)
    } else {
      clearTransientReorder(animated: true)
    }
    let finalRows = orderedRows(latestExternalRows, by: finalRowIDs)
    // The visible layers already occupy the proposal's stable slots. Install
    // the matching data order without a second movement, then remove the
    // temporary transforms only after the collection has accepted that order.
    requestDisplayUpdate(
      finalRows,
      reason: "native-drop",
      animatingDifferences: false,
      clearsTransientReorder: move != nil
    )
    resumeVisibleReportingIfReorderSettled()
    if let move {
      if let actions {
        actions.move(move) { [weak self] succeeded in
          guard let self, succeeded == false else { return }
          log.warning("native-drag[\(session.traceID)] persistence failed; rolling back")
          releaseHeldVisualOrder(reason: "reorder-rollback")
        }
      } else {
        releaseHeldVisualOrder(reason: "missing-move-action")
      }
    }
    return true
  }

  private func updateNativeReorder(at point: CGPoint) -> Int? {
    guard var session = reorderSession else { return nil }
    guard let proposal = dropProposal(at: point, session: session) else { return nil }
    let proposalChanged = session.proposal != proposal
    session.proposal = proposal
    reorderSession = session
    if proposalChanged {
      applyReorderLayout(session: session, proposal: proposal)
      log.debug(
        "native-drag[\(session.traceID)] proposal destination="
          + "\(String(describing: proposal.destination)) "
          + "point=(\(point.x),\(point.y)) indicator=\(proposal.indicatorIndex)"
      )
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    return proposal.indicatorIndex
  }

  private func applyReorderLayout(
    session: ReorderSession,
    proposal: DropProposal
  ) {
    applyTransientReorder(
      session: session,
      orderedRowIDs: proposal.orderedRowIDs,
      animated: true
    )
  }

  private func applyTransientReorder(
    session: ReorderSession,
    orderedRowIDs: [SidebarCollectionRow.ID],
    animated: Bool
  ) {
    guard orderedRowIDs.count == session.originalRowIDs.count else {
      log.error(
        "native-drag[\(session.traceID)] rejected transient order "
          + "original=\(session.originalRowIDs.count) proposed=\(orderedRowIDs.count)"
      )
      return
    }

    guard let firstRowID = session.originalRowIDs.first,
          let firstFrame = session.stableFramesByRowID[firstRowID]
    else { return }

    var targetFrameByRowID: [SidebarCollectionRow.ID: CGRect] = [:]
    var cursorY = session.forwardYSign > 0 ? firstFrame.minY : firstFrame.maxY
    for rowID in orderedRowIDs {
      guard var targetFrame = session.stableFramesByRowID[rowID] else { continue }
      if session.forwardYSign > 0 {
        targetFrame.origin.y = cursorY
        cursorY = targetFrame.maxY
      } else {
        targetFrame.origin.y = cursorY - targetFrame.height
        cursorY = targetFrame.minY
      }
      targetFrameByRowID[rowID] = targetFrame
    }
    let hiddenRowIDs = Set(session.draggedBlockIDs)

    for item in collectionView.visibleItems() {
      guard let indexPath = collectionView.indexPath(for: item),
            session.originalRowIDs.indices.contains(indexPath.item)
      else { continue }
      let rowID = session.originalRowIDs[indexPath.item]
      guard let sourceFrame = session.stableFramesByRowID[rowID],
            let targetFrame = targetFrameByRowID[rowID]
      else { continue }
      setTransientPresentation(
        for: item.view,
        transform: CATransform3DMakeTranslation(
          targetFrame.minX - sourceFrame.minX,
          targetFrame.minY - sourceFrame.minY,
          0
        ),
        opacity: hiddenRowIDs.contains(rowID) ? 0 : 1,
        animated: animated
      )
    }
  }

  private func clearTransientReorder(animated: Bool) {
    for item in collectionView.visibleItems() {
      setTransientPresentation(
        for: item.view,
        transform: CATransform3DIdentity,
        opacity: 1,
        animated: animated
      )
    }
  }

  private func setTransientPresentation(
    for view: NSView,
    transform: CATransform3D,
    opacity: Float,
    animated: Bool
  ) {
    view.wantsLayer = true
    guard let layer = view.layer else { return }

    let presentedTransform = layer.presentation()?.transform ?? layer.transform
    let presentedOpacity = layer.presentation()?.opacity ?? layer.opacity
    layer.removeAnimation(forKey: "sidebar-reorder-transform")
    layer.removeAnimation(forKey: "sidebar-reorder-opacity")

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = transform
    layer.opacity = opacity
    CATransaction.commit()

    guard animated,
          NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    else { return }

    if CATransform3DEqualToTransform(presentedTransform, transform) == false {
      let transformAnimation = CABasicAnimation(keyPath: "transform")
      transformAnimation.fromValue = NSValue(caTransform3D: presentedTransform)
      transformAnimation.toValue = NSValue(caTransform3D: transform)
      transformAnimation.duration = 0.16
      transformAnimation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
      layer.add(transformAnimation, forKey: "sidebar-reorder-transform")
    }

    if abs(presentedOpacity - opacity) > 0.001 {
      let opacityAnimation = CABasicAnimation(keyPath: "opacity")
      opacityAnimation.fromValue = presentedOpacity
      opacityAnimation.toValue = opacity
      opacityAnimation.duration = 0.1
      opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
      layer.add(opacityAnimation, forKey: "sidebar-reorder-opacity")
    }
  }

  private func dropProposal(
    at point: CGPoint,
    session: ReorderSession
  ) -> DropProposal? {
    if prefersChildDestination(at: point, session: session),
       let proposal = childDropProposal(at: point, session: session) {
      return proposal
    }
    return rootDropProposal(at: point, session: session)
  }

  private func prefersChildDestination(
    at point: CGPoint,
    session: ReorderSession
  ) -> Bool {
    guard let parentID = session.source.semanticParentID,
          point.x >= childDropIndentThreshold,
          let target = closestProjectedItem(toY: point.y, session: session)
    else { return false }

    return target.id == parentID || target.parentID == parentID || target.id == session.source.id
  }

  private var childDropIndentThreshold: CGFloat {
    Theme.sidebarNativeDefaultEdgeInsets + Theme.sidebarItemInnerSpacing + 12
  }

  private func closestProjectedItem(
    toY y: CGFloat,
    session: ReorderSession
  ) -> SidebarProjectedItem? {
    rows.compactMap { row -> (SidebarProjectedItem, CGFloat)? in
      guard let item = row.projectedItem,
            let frame = session.stableFramesByRowID[row.id]
      else { return nil }
      return (item, abs(frame.midY - y))
    }
    .min { $0.1 < $1.1 }?
    .0
  }

  private func childDropProposal(
    at point: CGPoint,
    session: ReorderSession
  ) -> DropProposal? {
    guard let parentID = session.source.semanticParentID,
          let parentRowID = rowID(for: parentID),
          let parent = projectedItem(for: parentRowID)
    else { return nil }

    let draggedBlock = Set(session.draggedBlockIDs)
    let candidateIDs = session.originalRowIDs.filter { rowID in
      draggedBlock.contains(rowID) == false && projectedItem(for: rowID)?.parentID == parentID
    }
    let anchorID = insertionAnchor(atY: point.y, candidateIDs: candidateIDs, session: session)
    var reorderedIDs = session.originalRowIDs.filter { draggedBlock.contains($0) == false }
    let insertionIndex: Int
    let indicatorIndex: Int
    let beforeID: ChatListItem.Identifier?
    let targetLane: SidebarOrderLane

    if let anchorID,
       let anchorIndex = reorderedIDs.firstIndex(of: anchorID),
       let displayedAnchorIndex = rows.firstIndex(where: { $0.id == anchorID }),
       let anchor = projectedItem(for: anchorID),
       let anchorOrderLane = anchor.orderLane {
      insertionIndex = anchorIndex
      indicatorIndex = displayedAnchorIndex
      beforeID = anchor.id
      targetLane = anchorOrderLane
    } else if let lastCandidateID = candidateIDs.last,
              let lastIndex = reorderedIDs.firstIndex(of: lastCandidateID),
              let last = projectedItem(for: lastCandidateID) {
      insertionIndex = indexAfterSubtree(startingAt: lastIndex, depth: last.depth, in: reorderedIDs)
      indicatorIndex = displayedIndexAfterSubtree(lastCandidateID)
      beforeID = nil
      guard let lastOrderLane = last.orderLane else { return nil }
      targetLane = lastOrderLane
    } else if let parentIndex = reorderedIDs.firstIndex(of: parentRowID),
              let displayedParentIndex = rows.firstIndex(where: { $0.id == parentRowID }) {
      insertionIndex = parentIndex + 1
      indicatorIndex = displayedParentIndex + 1
      beforeID = nil
      guard let fallbackTargetLane = session.source.orderLane ?? parent.orderLane else { return nil }
      targetLane = fallbackTargetLane
    } else {
      return nil
    }

    reorderedIDs.insert(contentsOf: session.draggedBlockIDs, at: insertionIndex)
    return DropProposal(
      destination: .child(parentID: parentID, beforeID: beforeID),
      orderedRowIDs: reorderedIDs,
      indicatorIndex: indicatorIndex,
      targetLane: targetLane
    )
  }

  private func rootDropProposal(
    at point: CGPoint,
    session: ReorderSession
  ) -> DropProposal? {
    let draggedBlock = Set(session.draggedBlockIDs)
    let allRootIDs = session.originalRowIDs.filter { projectedItem(for: $0)?.parentID == nil }
    let candidateIDs = session.originalRowIDs.filter { rowID in
      draggedBlock.contains(rowID) == false && projectedItem(for: rowID)?.parentID == nil
    }
    var reorderedIDs = session.originalRowIDs.filter { draggedBlock.contains($0) == false }

    if let firstRootID = allRootIDs.first,
       let firstRootFrame = stableSubtreeFrame(for: firstRootID, session: session),
       isBefore(point.y, firstRootFrame.midY, session: session) {
      let insertionIndex = firstChatIndex(in: reorderedIDs)
      let indicatorIndex = firstDisplayedChatIndex()
      let beforeID = candidateIDs.compactMap { projectedItem(for: $0) }
        .first(where: { $0.orderLane == .pinned })?.id
      reorderedIDs.insert(contentsOf: session.draggedBlockIDs, at: insertionIndex)
      return DropProposal(
        destination: .root(lane: .pinned, beforeID: beforeID),
        orderedRowIDs: reorderedIDs,
        indicatorIndex: indicatorIndex,
        targetLane: .pinned
      )
    }

    if let lastRootID = allRootIDs.last,
       let lastRootFrame = stableSubtreeFrame(for: lastRootID, session: session),
       isAfter(point.y, lastRootFrame.midY, session: session) {
      let insertionIndex = indexAfterLastChat(in: reorderedIDs)
      let indicatorIndex = firstTrailingRowIndex()
      reorderedIDs.insert(contentsOf: session.draggedBlockIDs, at: insertionIndex)
      return DropProposal(
        destination: .root(lane: .normal, beforeID: nil),
        orderedRowIDs: reorderedIDs,
        indicatorIndex: indicatorIndex,
        targetLane: .normal
      )
    }

    guard candidateIDs.isEmpty == false else { return nil }
    let anchorID = insertionAnchor(atY: point.y, candidateIDs: candidateIDs, session: session)
    let insertionIndex: Int
    let indicatorIndex: Int
    let target: SidebarProjectedItem
    let beforeID: ChatListItem.Identifier?

    if let anchorID,
       let anchorIndex = reorderedIDs.firstIndex(of: anchorID),
       let displayedAnchorIndex = rows.firstIndex(where: { $0.id == anchorID }),
       let anchor = projectedItem(for: anchorID) {
      insertionIndex = anchorIndex
      indicatorIndex = displayedAnchorIndex
      target = anchor
      beforeID = anchor.id
    } else if let lastCandidateID = candidateIDs.last,
              let lastIndex = reorderedIDs.firstIndex(of: lastCandidateID),
              let last = projectedItem(for: lastCandidateID) {
      insertionIndex = indexAfterSubtree(startingAt: lastIndex, depth: last.depth, in: reorderedIDs)
      indicatorIndex = displayedIndexAfterSubtree(lastCandidateID)
      target = last
      beforeID = nil
    } else {
      return nil
    }

    guard let targetLane = target.orderLane else { return nil }
    reorderedIDs.insert(contentsOf: session.draggedBlockIDs, at: insertionIndex)
    return DropProposal(
      destination: .root(lane: targetLane, beforeID: beforeID),
      orderedRowIDs: reorderedIDs,
      indicatorIndex: indicatorIndex,
      targetLane: targetLane
    )
  }

  private func insertionAnchor(
    atY y: CGFloat,
    candidateIDs: [SidebarCollectionRow.ID],
    session: ReorderSession
  ) -> SidebarCollectionRow.ID? {
    candidateIDs.first { candidateID in
      guard let frame = stableSubtreeFrame(for: candidateID, session: session) else { return false }
      return isBefore(y, frame.midY, session: session)
    }
  }

  private func isBefore(
    _ y: CGFloat,
    _ threshold: CGFloat,
    session: ReorderSession
  ) -> Bool {
    (y - threshold) * session.forwardYSign < 0
  }

  private func isAfter(
    _ y: CGFloat,
    _ threshold: CGFloat,
    session: ReorderSession
  ) -> Bool {
    (y - threshold) * session.forwardYSign > 0
  }

  private func firstChatIndex(in rowIDs: [SidebarCollectionRow.ID]) -> Int {
    rowIDs.firstIndex(where: { projectedItem(for: $0) != nil })
      ?? indexAfterLastLeadingRow(in: rowIDs)
  }

  private func indexAfterLastChat(in rowIDs: [SidebarCollectionRow.ID]) -> Int {
    guard let lastChatIndex = rowIDs.lastIndex(where: { projectedItem(for: $0) != nil }) else {
      return indexAfterLastLeadingRow(in: rowIDs)
    }
    return rowIDs.index(after: lastChatIndex)
  }

  private func indexAfterLastLeadingRow(in rowIDs: [SidebarCollectionRow.ID]) -> Int {
    rowIDs.firstIndex(where: { rowID in
      switch rowID {
      case .newThread, .emptyState:
        return true
      default:
        return false
      }
    }) ?? rowIDs.endIndex
  }

  private func firstDisplayedChatIndex() -> Int {
    rows.firstIndex(where: { $0.projectedItem != nil })
      ?? firstTrailingRowIndex()
  }

  private func firstTrailingRowIndex() -> Int {
    rows.firstIndex(where: { row in
      switch row.id {
      case .newThread, .emptyState:
        return true
      default:
        return false
      }
    }) ?? rows.count
  }

  private func stableSubtreeFrame(
    for rowID: SidebarCollectionRow.ID,
    session: ReorderSession
  ) -> CGRect? {
    guard let startIndex = session.originalRowIDs.firstIndex(of: rowID),
          let source = projectedItem(for: rowID)
    else { return nil }

    var result: CGRect?
    var index = startIndex
    while session.originalRowIDs.indices.contains(index) {
      let currentRowID = session.originalRowIDs[index]
      if index != startIndex {
        guard let current = projectedItem(for: currentRowID), current.depth > source.depth else { break }
      }
      if let frame = session.stableFramesByRowID[currentRowID] {
        result = result.map { $0.union(frame) } ?? frame
      }
      index += 1
    }
    return result
  }

  private func rowID(for id: ChatListItem.Identifier) -> SidebarCollectionRow.ID? {
    let rowID = SidebarCollectionRow.ID.chat(id)
    return modelRowByID[rowID] == nil ? nil : rowID
  }

  private func displayedIndexAfterSubtree(_ rowID: SidebarCollectionRow.ID) -> Int {
    guard let startIndex = rows.firstIndex(where: { $0.id == rowID }),
          let source = projectedItem(for: rowID)
    else { return rows.count }

    var index = startIndex + 1
    while rows.indices.contains(index) {
      guard let item = projectedItem(for: rows[index].id), item.depth > source.depth else { break }
      index += 1
    }
    return index
  }

  private func indexAfterSubtree(
    startingAt startIndex: Int,
    depth: Int,
    in rowIDs: [SidebarCollectionRow.ID]
  ) -> Int {
    var index = startIndex + 1
    while rowIDs.indices.contains(index) {
      guard let item = projectedItem(for: rowIDs[index]), item.depth > depth else { break }
      index += 1
    }
    return index
  }

  private func draggedBlockIDs(
    for sourceID: SidebarCollectionRow.ID,
    in rowIDs: [SidebarCollectionRow.ID]
  ) -> [SidebarCollectionRow.ID] {
    guard let sourceIndex = rowIDs.firstIndex(of: sourceID),
          let source = projectedItem(for: sourceID)
    else { return [sourceID] }

    var result = [sourceID]
    var index = rowIDs.index(after: sourceIndex)
    while index < rowIDs.endIndex {
      guard let item = projectedItem(for: rowIDs[index]), item.depth > source.depth else { break }
      result.append(rowIDs[index])
      index = rowIDs.index(after: index)
    }
    return result
  }

  private func collectionMove(
    for session: ReorderSession,
    proposal: DropProposal,
    sourceLane: SidebarOrderLane
  ) -> SidebarCollectionMove? {
    let orderedItems = proposal.orderedRowIDs.compactMap { projectedItem(for: $0) }
    let siblings: [SidebarProjectedItem]
    let hierarchyChange: SidebarCollectionMove.HierarchyChange?

    switch proposal.destination {
    case .root:
      siblings = orderedItems.filter { item in
        (item.parentID == nil && item.orderLane == proposal.targetLane) || item.id == session.source.id
      }
      hierarchyChange = session.source.semanticParentID != nil && session.source.parentID != nil
        ? .detach(session.source.id)
        : nil
    case let .child(parentID, _):
      siblings = orderedItems.filter { item in
        (item.parentID == parentID && item.orderLane == proposal.targetLane)
          || item.id == session.source.id
      }
      hierarchyChange = session.source.parentID == nil
        ? .attach(session.source.id, parentID: parentID)
        : nil
    }

    guard let newIndex = siblings.firstIndex(where: { $0.id == session.source.id }) else { return nil }
    if hierarchyChange == nil,
       sourceLane == proposal.targetLane,
       originalSiblingIDs(
         for: session,
         destination: proposal.destination,
         targetLane: proposal.targetLane
       ) == siblings.map(\.id) {
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
    destination: DropProposal.Destination,
    targetLane: SidebarOrderLane
  ) -> [ChatListItem.Identifier] {
    session.originalRowIDs.compactMap { rowID -> SidebarProjectedItem? in
      guard let item = projectedItem(for: rowID) else { return nil }
      switch destination {
      case let .root(lane, _):
        return item.parentID == nil && item.orderLane == lane ? item : nil
      case let .child(parentID, _):
        return item.parentID == parentID && item.orderLane == targetLane ? item : nil
      }
    }
    .map(\.id)
  }

  private func cancelReorderForExternalUpdate() {
    guard reorderSession != nil else { return }
    clearTransientReorder(animated: true)
    reorderSession = nil
    pendingDisplayUpdate = nil
    resumeVisibleReportingIfReorderSettled()
  }

  private func holdVisualOrder(_ rowIDs: [SidebarCollectionRow.ID]) {
    heldRowsTask?.cancel()
    heldRowIDs = rowIDs
    heldRowsTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: Self.optimisticOrderHoldDuration)
      } catch {
        return
      }
      guard let self, heldRowIDs == rowIDs else { return }
      log.warning("optimistic reorder hold expired before model acknowledgement")
      heldRowIDs = nil
      requestDisplayUpdate(
        latestExternalRows,
        reason: "order-hold-expired",
        animatingDifferences: nil
      )
    }
  }

  private func releaseHeldVisualOrder(reason: String) {
    heldRowsTask?.cancel()
    heldRowsTask = nil
    heldRowIDs = nil
    requestDisplayUpdate(
      latestExternalRows,
      reason: reason,
      animatingDifferences: true
    )
  }

  private func arrangedRows(from externalRows: [SidebarCollectionRow]) -> [SidebarCollectionRow] {
    let externalIDs = externalRows.map(\.id)
    if let session = reorderSession, Set(session.originalRowIDs) == Set(externalIDs) {
      // Native drag targeting is calculated against this frozen display order.
      // Content can refresh, but model order updates wait until the drag ends.
      return orderedRows(externalRows, by: session.originalRowIDs)
    }
    if let heldRowIDs, Set(heldRowIDs) == Set(externalIDs) {
      if heldRowIDs == externalIDs {
        log.info("optimistic reorder acknowledged by model")
        self.heldRowIDs = nil
        heldRowsTask?.cancel()
        heldRowsTask = nil
        return externalRows
      }
      return orderedRows(externalRows, by: heldRowIDs)
    }
    if heldRowIDs != nil {
      log.warning("optimistic reorder cancelled by identity-changing model update")
      self.heldRowIDs = nil
      heldRowsTask?.cancel()
      heldRowsTask = nil
    }
    return externalRows
  }

  private func orderedRows(
    _ sourceRows: [SidebarCollectionRow],
    by rowIDs: [SidebarCollectionRow.ID]
  ) -> [SidebarCollectionRow] {
    let rowsByID = Dictionary(sourceRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return rowIDs.compactMap { rowsByID[$0] }
  }

  private func handleScrollRequest(_ request: SidebarCollectionScrollRequest?) {
    guard let request, request.token != lastScrollRequestToken else { return }
    lastScrollRequestToken = request.token
    guard let index = rows.firstIndex(where: { $0.projectedItem?.id == request.itemID }) else { return }
    collectionView.scrollToItems(
      at: [IndexPath(item: index, section: 0)],
      scrollPosition: .centeredVertically
    )
  }

  private func reportVisibleChatIDs() {
    guard visibleReportingSuspendedForReorder == false else { return }
    let visibleIDs: Set<ChatListItem.Identifier> = Set(
      collectionView.indexPathsForVisibleItems().compactMap { indexPath in
        guard rows.indices.contains(indexPath.item) else { return nil }
        return rows[indexPath.item].projectedItem?.id
      }
    )
    guard visibleIDs != lastVisibleChatIDs else { return }
    lastVisibleChatIDs = visibleIDs

    // Diffable completion can run synchronously from SwiftUI's representable
    // update. Yield before feeding visibility back into SwiftUI state.
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self,
            visibleReportingSuspendedForReorder == false,
            lastVisibleChatIDs == visibleIDs
      else { return }
      actions?.visibleChatIDsChanged(visibleIDs)
    }
  }

  private func refreshVisibleItems(only rowIDs: Set<SidebarCollectionRow.ID>? = nil) {
    guard let content else { return }

    for item in collectionView.visibleItems() {
      guard let item = item as? SidebarHostedCollectionItem,
            let indexPath = collectionView.indexPath(for: item),
            rows.indices.contains(indexPath.item)
      else { continue }

      let row = rows[indexPath.item]
      if let rowIDs, rowIDs.contains(row.id) == false { continue }
      item.setContent(
        content(row),
        canToggleDisclosure: row.projectedItem?.isExpandable == true,
        onToggleDisclosure: { [weak self] in
          guard let id = row.projectedItem?.id else { return }
          self?.actions?.toggleDisclosure(id)
        }
      )
      scheduleDragPreview(for: row.id)
    }
  }
}
