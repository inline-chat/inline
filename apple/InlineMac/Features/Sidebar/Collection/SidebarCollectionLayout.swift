import AppKit
import InlineKit
import InlineMacSidebarModel
import InlineMacUI

/// Immutable row lookup used by both diffable data source updates and custom
/// layout transitions. Collection items are always configured by semantic ID,
/// never by a potentially stale array index.
struct SidebarBodyPresentation {
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
    var seenIDs = Set<SidebarCollectionRow.ID>()
    let rows = rows.filter { seenIDs.insert($0.id).inserted }
    let orderedIDs = rows.map(\.id)
    self.generation = generation
    self.rows = rows
    self.orderedIDs = orderedIDs
    rowByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.renderState = renderState
  }
}

struct SidebarBodyDisplayUpdate {
  let presentation: SidebarBodyPresentation
  let reason: String
  let animatingDifferences: Bool
  var completions: [() -> Void]
}

struct SidebarBodyLayoutDrag: Equatable {
  let sourceIDs: Set<SidebarCollectionRow.ID>
  let destinationIndex: Int
  let slotHeight: CGFloat
  let hidesPinnedHeader: Bool
}

struct SidebarBodyLayoutDisclosure: Equatable {
  let affectedIDs: Set<SidebarCollectionRow.ID>
  let trailingIDs: Set<SidebarCollectionRow.ID>
  let collapsedOffsetY: CGFloat
  let hidesAffectedRows: Bool
}

/// A concrete AppKit flow layout with a narrow product-geometry projection.
///
/// `NSCollectionViewFlowLayout` remains the owner of collection update
/// bookkeeping and survivor motion. Inline only projects the drag reservation,
/// disclosure offsets, and nonvisual pinned-lane boundary onto the resulting
/// row geometry.
final class SidebarCollectionBodyLayout: NSCollectionViewFlowLayout {
  private(set) var slotFrame: CGRect?
  private(set) var laneBoundaryFrame: CGRect?
  private(set) var scrollEdgeContentHeight: CGFloat = 0

  private var presentation: SidebarBodyPresentation?
  private var drag: SidebarBodyLayoutDrag?
  private var emptyPinned: SidebarCollectionEmptyPinnedLayoutState?
  private var disclosure: SidebarBodyLayoutDisclosure?
  private var settlingSourceIDs: Set<SidebarCollectionRow.ID> = []
  private var itemAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
  private var orderedItemAttributes: [NSCollectionViewLayoutAttributes] = []
  private var contentSize = CGSize.zero

  func configure(
    presentation: SidebarBodyPresentation,
    drag: SidebarBodyLayoutDrag?,
    emptyPinned: SidebarCollectionEmptyPinnedLayoutState?,
    disclosure: SidebarBodyLayoutDisclosure?,
    settlingSourceIDs: Set<SidebarCollectionRow.ID>,
    invalidatesLayout: Bool
  ) {
    self.presentation = presentation
    self.drag = drag
    self.emptyPinned = emptyPinned
    self.disclosure = disclosure
    self.settlingSourceIDs = settlingSourceIDs
    if invalidatesLayout {
      invalidateLayout()
    }
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
    // AppKit has already assigned `collectionView.bounds` when it asks this
    // question, so comparing against that value always reports no change.
    // Compare against the width used by the last prepared layout instead.
    return abs(newBounds.width - contentSize.width) > 0.5
  }

  override func prepare() {
    super.prepare()
    guard let collectionView else { return }

    let horizontalInset = Theme.sidebarNativeDefaultEdgeInsets
    let collectionWidth = collectionView.bounds.width
    let insetWidth = max(collectionWidth - horizontalInset * 2, 1)
    var attributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    var orderedAttributes: [NSCollectionViewLayoutAttributes] = []
    let rows = presentation?.rows ?? []
    let plannedRows = rows.map { row in
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
    let plannedDrag = drag.map { drag in
      SidebarCollectionDragLayoutState(
        sourceIDs: drag.sourceIDs,
        destinationIndex: drag.destinationIndex,
        slotHeight: Double(drag.slotHeight),
        hidesPinnedHeader: drag.hidesPinnedHeader
      )
    }
    let plan = SidebarCollectionDragLayoutPlanner.plan(
      rows: plannedRows,
      drag: plannedDrag,
      emptyPinned: emptyPinned
    )

    slotFrame = plan.slotFrame.map {
      CGRect(
        x: 0,
        y: CGFloat($0.minY),
        width: collectionWidth,
        height: CGFloat($0.height)
      )
    }
    laneBoundaryFrame = nil
    for (index, row) in rows.enumerated() {
      let indexPath = IndexPath(item: index, section: 0)
      let itemAttributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
      let verticalFrame = plan.rowFrames[row.id]
        ?? SidebarCollectionVerticalFrame(minY: 0, height: 0)
      itemAttributes.frame = itemFrame(
        for: row,
        y: CGFloat(verticalFrame.minY),
        height: CGFloat(verticalFrame.height),
        collectionWidth: collectionWidth,
        horizontalInset: horizontalInset,
        insetWidth: insetWidth
      )
      if disclosure?.trailingIDs.contains(row.id) == true {
        // Keep the tail's model geometry at the collapsed endpoint. AppKit
        // then materializes survivors such as New Thread even when their
        // expanded frame is below the viewport; the animator presents them
        // at the expanded endpoint with one shared positive translation.
        itemAttributes.frame.origin.y += disclosure?.collapsedOffsetY ?? 0
      }
      itemAttributes.alpha = plan.visibleRowIDs.contains(row.id)
        && settlingSourceIDs.contains(row.id) == false
        && (disclosure?.hidesAffectedRows != true
          || disclosure?.affectedIDs.contains(row.id) != true) ? 1 : 0
      attributes[indexPath] = itemAttributes
      orderedAttributes.append(itemAttributes)
      if case .sectionHeader(.content, _) = row.kind {
        laneBoundaryFrame = itemAttributes.frame
      } else if laneBoundaryFrame == nil, case .timelineHeader = row.kind {
        laneBoundaryFrame = itemAttributes.frame
      }
    }

    itemAttributes = attributes
    orderedItemAttributes = orderedAttributes
    // The collection view's bounds are its document geometry and can still
    // contain the previous snapshot's height while a shorter mode is being
    // applied. Using that as the minimum makes the old height self-sustaining.
    // The clip view is the actual viewport and lets the document shrink while
    // still filling a short sidebar.
    let viewportHeight = collectionView.enclosingScrollView?.contentView.bounds.height ?? 0
    scrollEdgeContentHeight = CGFloat(plan.contentHeight)
    let trailingScrollPadding: CGFloat = rows.isEmpty ? 0 : 20
    contentSize = CGSize(
      width: collectionView.bounds.width,
      height: max(CGFloat(plan.contentHeight) + trailingScrollPadding, viewportHeight)
    )
  }

  override var collectionViewContentSize: NSSize {
    contentSize
  }

  override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
    if disclosure != nil {
      // Disclosure staging deliberately overlaps hidden affected rows with a
      // shifted tail, so logical order is temporarily not vertical order.
      // Preserve every hidden transition participant for the 160 ms animation;
      // ordinary scrolling returns to the binary-search path below.
      return orderedItemAttributes.filter { attributes in
        attributes.alpha == 0 || attributes.frame.intersects(rect)
      }
    }

    // Rows are vertically ordered. Avoid scanning the entire All Chats model
    // for every clip-view bounds notification while the user scrolls.
    var lowerBound = 0
    var upperBound = orderedItemAttributes.count
    while lowerBound < upperBound {
      let middle = (lowerBound + upperBound) / 2
      if orderedItemAttributes[middle].frame.maxY <= rect.minY {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }

    var visible: [NSCollectionViewLayoutAttributes] = []
    var index = lowerBound
    while index < orderedItemAttributes.count {
      let attributes = orderedItemAttributes[index]
      guard attributes.frame.minY < rect.maxY else { break }
      if attributes.frame.intersects(rect) {
        visible.append(attributes)
      }
      index += 1
    }
    return visible
  }

  override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
    itemAttributes[indexPath]
  }

  private func itemFrame(
    for row: SidebarCollectionRow,
    y: CGFloat,
    height: CGFloat,
    collectionWidth: CGFloat,
    horizontalInset: CGFloat,
    insetWidth: CGFloat
  ) -> CGRect {
    if row.usesFullWidthCollectionLayout {
      return CGRect(x: 0, y: y, width: collectionWidth, height: height)
    }
    return CGRect(x: horizontalInset, y: y, width: insetWidth, height: height)
  }
}
