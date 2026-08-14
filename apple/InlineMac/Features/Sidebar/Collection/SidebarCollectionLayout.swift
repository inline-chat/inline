import AppKit
import InlineKit
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

/// Owns only physical collection geometry: rows, the one drag reservation,
/// the nonvisual pinned-lane boundary, and diffable move/fade attributes.
final class SidebarCollectionBodyLayout: NSCollectionViewLayout {
  private struct SectionDisclosureTransition {
    let section: SidebarCollectionRow.SectionHeader
    let isExpanding: Bool
    let affectedRowIDs: Set<SidebarCollectionRow.ID>
  }

  private(set) var slotFrame: CGRect?
  private(set) var laneBoundaryFrame: CGRect?
  private(set) var scrollEdgeContentHeight: CGFloat = 0

  private var presentation: SidebarBodyPresentation?
  private var drag: SidebarBodyLayoutDrag?
  private var emptyPinned: SidebarCollectionEmptyPinnedLayoutState?
  private var settlingSourceIDs: Set<SidebarCollectionRow.ID> = []
  private var itemAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
  private var transitionFromIDs: [SidebarCollectionRow.ID] = []
  private var transitionFromAttributes: [
    SidebarCollectionRow.ID: NSCollectionViewLayoutAttributes
  ] = [:]
  private var sectionDisclosureTransition: SectionDisclosureTransition?
  private var hasTransitionSource = false
  private var contentSize = CGSize.zero

  func prepareTransition(
    from previousPresentation: SidebarBodyPresentation?,
    to nextPresentation: SidebarBodyPresentation
  ) {
    hasTransitionSource = previousPresentation != nil
    transitionFromIDs = previousPresentation?.orderedIDs ?? []
    transitionFromAttributes = Dictionary(
      uniqueKeysWithValues: transitionFromIDs.enumerated().compactMap { index, id in
        guard let attributes = itemAttributes[IndexPath(item: index, section: 0)]?.copy()
          as? NSCollectionViewLayoutAttributes
        else { return nil }
        return (id, attributes)
      }
    )
    sectionDisclosureTransition = Self.sectionDisclosureTransition(
      from: previousPresentation,
      to: nextPresentation
    )
  }

  func configure(
    presentation: SidebarBodyPresentation,
    drag: SidebarBodyLayoutDrag?,
    emptyPinned: SidebarCollectionEmptyPinnedLayoutState?,
    settlingSourceIDs: Set<SidebarCollectionRow.ID>
  ) {
    self.presentation = presentation
    self.drag = drag
    self.emptyPinned = emptyPinned
    self.settlingSourceIDs = settlingSourceIDs
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
      itemAttributes.alpha = plan.visibleRowIDs.contains(row.id)
        && settlingSourceIDs.contains(row.id) == false ? 1 : 0
      attributes[indexPath] = itemAttributes
      if case .sectionHeader(.content, _) = row.kind {
        laneBoundaryFrame = itemAttributes.frame
      } else if laneBoundaryFrame == nil, case .timelineHeader = row.kind {
        laneBoundaryFrame = itemAttributes.frame
      }
    }

    itemAttributes = attributes
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
    itemAttributes.values.filter { attributes in
      attributes.alpha == 0 || attributes.frame.intersects(rect)
    }
  }

  override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
    itemAttributes[indexPath]
  }

  override func initialLayoutAttributesForAppearingItem(
    at itemIndexPath: IndexPath
  ) -> NSCollectionViewLayoutAttributes? {
    guard let presentation,
          presentation.orderedIDs.indices.contains(itemIndexPath.item),
          let targetAttributes = layoutAttributesForItem(at: itemIndexPath)?.copy()
      as? NSCollectionViewLayoutAttributes
    else { return nil }
    let rowID = presentation.orderedIDs[itemIndexPath.item]
    if let previous = transitionFromAttributes[rowID]?.copy()
      as? NSCollectionViewLayoutAttributes {
      targetAttributes.frame = previous.frame
      targetAttributes.alpha = previous.alpha
      return targetAttributes
    }
    // The initial snapshot has no source scene to animate from. Returning an
    // invisible appearance attribute here lets a full-height window display
    // before all visible collection items have reached their final state.
    guard hasTransitionSource else { return targetAttributes }
    guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else {
      return targetAttributes
    }
    if sectionDisclosureTransition?.isExpanding == true,
       sectionDisclosureTransition?.affectedRowIDs.contains(rowID) == true,
       let collapsed = collapsedAttributes(for: targetAttributes) {
      return collapsed
    }
    targetAttributes.alpha = 0
    targetAttributes.frame.origin.y -= 4
    return targetAttributes
  }

  override func finalLayoutAttributesForDisappearingItem(
    at itemIndexPath: IndexPath
  ) -> NSCollectionViewLayoutAttributes? {
    guard transitionFromIDs.indices.contains(itemIndexPath.item),
          let attributes = transitionFromAttributes[
            transitionFromIDs[itemIndexPath.item]
          ]?.copy()
      as? NSCollectionViewLayoutAttributes
    else { return nil }
    let rowID = transitionFromIDs[itemIndexPath.item]
    if let destinationIndex = presentation?.orderedIDs.firstIndex(of: rowID),
       let destination = layoutAttributesForItem(
         at: IndexPath(item: destinationIndex, section: 0)
       )?.copy() as? NSCollectionViewLayoutAttributes {
      attributes.frame = destination.frame
      attributes.alpha = destination.alpha
      return attributes
    }
    guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else {
      return attributes
    }
    if sectionDisclosureTransition?.isExpanding == false,
       sectionDisclosureTransition?.affectedRowIDs.contains(rowID) == true,
       let collapsed = collapsedAttributes(for: attributes) {
      return collapsed
    }
    attributes.alpha = 0
    attributes.frame.origin.y -= 4
    return attributes
  }

  override func finalizeCollectionViewUpdates() {
    super.finalizeCollectionViewUpdates()
    transitionFromIDs.removeAll()
    transitionFromAttributes.removeAll()
    sectionDisclosureTransition = nil
  }

  private func collapsedAttributes(
    for source: NSCollectionViewLayoutAttributes
  ) -> NSCollectionViewLayoutAttributes? {
    guard let sectionDisclosureTransition,
          let presentation,
          let headerIndex = presentation.orderedIDs.firstIndex(
            of: .sectionHeader(sectionDisclosureTransition.section)
          ),
          let headerAttributes = layoutAttributesForItem(
            at: IndexPath(item: headerIndex, section: 0)
          ),
          let collapsed = source.copy() as? NSCollectionViewLayoutAttributes
    else { return nil }

    collapsed.frame = CGRect(
      x: source.frame.minX,
      y: headerAttributes.frame.maxY,
      width: source.frame.width,
      height: 0
    )
    collapsed.alpha = 0
    return collapsed
  }

  private static func sectionDisclosureTransition(
    from previous: SidebarBodyPresentation?,
    to next: SidebarBodyPresentation
  ) -> SectionDisclosureTransition? {
    guard let previous else { return nil }

    let changedSections: [(
      section: SidebarCollectionRow.SectionHeader,
      isExpanding: Bool
    )] = SidebarCollectionRow.SectionHeader.allCases.compactMap { section in
      let previousExpanded = previous.rowByID[.sectionHeader(section)]?
        .sectionHeader?.isExpanded
      let nextExpanded = next.rowByID[.sectionHeader(section)]?
        .sectionHeader?.isExpanded
      guard let previousExpanded, let nextExpanded, previousExpanded != nextExpanded else {
        return nil
      }
      return (section: section, isExpanding: nextExpanded)
    }
    guard changedSections.count == 1, let changedSection = changedSections.first else {
      return nil
    }

    let previousIDs = Set(previous.orderedIDs)
    let nextIDs = Set(next.orderedIDs)
    let affectedRowIDs = previousIDs.symmetricDifference(nextIDs).filter { rowID in
      let row = next.rowByID[rowID] ?? previous.rowByID[rowID]
      return switch row?.kind {
      case let .chat(item):
        item.lane == (changedSection.section == .pinned ? .pinned : .normal)
      case .emptyState:
        changedSection.section == .content
      default:
        false
      }
    }
    guard affectedRowIDs.isEmpty == false else { return nil }

    return SectionDisclosureTransition(
      section: changedSection.section,
      isExpanding: changedSection.isExpanding,
      affectedRowIDs: Set(affectedRowIDs)
    )
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
