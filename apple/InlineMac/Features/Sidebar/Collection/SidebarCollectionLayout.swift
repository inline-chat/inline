import AppKit
import InlineKit

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
  let targetLane: SidebarOrderLane
}

/// Owns only physical collection geometry: rows, the one drag reservation,
/// the nonvisual pinned-lane boundary, and diffable move/fade attributes.
final class SidebarCollectionBodyLayout: NSCollectionViewLayout {
  private(set) var slotFrame: CGRect?
  private(set) var laneBoundaryFrame: CGRect?

  private var presentation: SidebarBodyPresentation?
  private var drag: SidebarBodyLayoutDrag?
  private var settlingSourceIDs: Set<SidebarCollectionRow.ID> = []
  private var itemAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
  private var transitionFromIDs: [SidebarCollectionRow.ID] = []
  private var transitionFromAttributes: [
    SidebarCollectionRow.ID: NSCollectionViewLayoutAttributes
  ] = [:]
  private var contentSize = CGSize.zero

  func prepareTransition(from presentation: SidebarBodyPresentation?) {
    transitionFromIDs = presentation?.orderedIDs ?? []
    transitionFromAttributes = Dictionary(
      uniqueKeysWithValues: transitionFromIDs.enumerated().compactMap { index, id in
        guard let attributes = itemAttributes[IndexPath(item: index, section: 0)]?.copy()
          as? NSCollectionViewLayoutAttributes
        else { return nil }
        return (id, attributes)
      }
    )
  }

  func configure(
    presentation: SidebarBodyPresentation,
    drag: SidebarBodyLayoutDrag?,
    settlingSourceIDs: Set<SidebarCollectionRow.ID>
  ) {
    self.presentation = presentation
    self.drag = drag
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
    var y: CGFloat = 0
    var reducedIndex = 0
    var insertedSlot = false
    let rows = presentation?.rows ?? []

    func insertSlotIfNeeded() {
      guard insertedSlot == false,
            let drag,
            reducedIndex == drag.destinationIndex
      else { return }

      slotFrame = CGRect(x: 0, y: y, width: collectionWidth, height: drag.slotHeight)
      y += drag.slotHeight
      insertedSlot = true
    }

    slotFrame = nil
    laneBoundaryFrame = nil
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

      // The empty-lane guide teaches pinning until the pointer enters that
      // lane. The exact drag reservation then replaces it, so the layout never
      // presents two destination gaps.
      if row.id == .pinDropGuide, drag?.targetLane == .pinned {
        insertSlotIfNeeded()
        itemAttributes.frame = CGRect(x: 0, y: y, width: collectionWidth, height: 0)
        itemAttributes.alpha = 0
        attributes[indexPath] = itemAttributes
        reducedIndex += 1
        continue
      }

      insertSlotIfNeeded()
      itemAttributes.frame = itemFrame(
        for: row,
        y: y,
        collectionWidth: collectionWidth,
        horizontalInset: horizontalInset,
        insetWidth: insetWidth
      )
      itemAttributes.alpha = settlingSourceIDs.contains(row.id) ? 0 : 1
      attributes[indexPath] = itemAttributes
      if case .sectionHeader(.content, _) = row.kind {
        laneBoundaryFrame = itemAttributes.frame
      }
      y += row.height
      reducedIndex += 1
    }

    insertSlotIfNeeded()
    if let drag, insertedSlot == false {
      slotFrame = CGRect(x: 0, y: y, width: collectionWidth, height: drag.slotHeight)
      y += drag.slotHeight
    }

    itemAttributes = attributes
    // The collection view's bounds are its document geometry and can still
    // contain the previous snapshot's height while a shorter mode is being
    // applied. Using that as the minimum makes the old height self-sustaining.
    // The clip view is the actual viewport and lets the document shrink while
    // still filling a short sidebar.
    let viewportHeight = collectionView.enclosingScrollView?.contentView.bounds.height ?? 0
    let trailingScrollPadding = rows.last.map { min($0.height, 44) } ?? 0
    contentSize = CGSize(
      width: collectionView.bounds.width,
      height: max(y + trailingScrollPadding, viewportHeight)
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
    guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else {
      return targetAttributes
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
    attributes.alpha = 0
    attributes.frame.origin.y -= 4
    return attributes
  }

  override func finalizeCollectionViewUpdates() {
    super.finalizeCollectionViewUpdates()
    transitionFromIDs.removeAll()
    transitionFromAttributes.removeAll()
  }

  private func itemFrame(
    for row: SidebarCollectionRow,
    y: CGFloat,
    collectionWidth: CGFloat,
    horizontalInset: CGFloat,
    insetWidth: CGFloat
  ) -> CGRect {
    if row.projectedItem != nil || row.isSectionHeader || row.id == .pinDropGuide {
      return CGRect(x: 0, y: y, width: collectionWidth, height: row.height)
    }
    return CGRect(x: horizontalInset, y: y, width: insetWidth, height: row.height)
  }
}
