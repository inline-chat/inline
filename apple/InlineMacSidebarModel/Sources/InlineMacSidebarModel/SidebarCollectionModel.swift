import Foundation

/// Describes which nodes a sidebar container may own in the presentation tree.
///
/// A reply-thread parent uses ``semanticParentOnly``. A user folder uses
/// ``any`` without changing the tree, slot, or move machinery.
public enum SidebarCollectionChildPolicy: Hashable, Sendable {
  case none
  case semanticParentOnly
  case any
}

/// Controls whether a move carries presentation descendants. Same-section
/// reorders move a complete group; pin/unpin transfers may move only the
/// dialog whose own section membership changes.
public enum SidebarCollectionMoveScope: Hashable, Sendable {
  case attachedSubtree
  case sourceOnly
}

/// One stable semantic node in the sidebar hierarchy.
///
/// `semanticParentID` is durable product identity. `childIDs` is the current
/// presentation containment. Detaching a reply changes containment while
/// preserving its semantic parent.
public struct SidebarCollectionNode<NodeID: Hashable>: Hashable {
  public let id: NodeID
  public let semanticParentID: NodeID?
  public let childPolicy: SidebarCollectionChildPolicy
  public let childIDs: [NodeID]
  public let isExpanded: Bool

  public init(
    id: NodeID,
    semanticParentID: NodeID? = nil,
    childPolicy: SidebarCollectionChildPolicy = .none,
    childIDs: [NodeID] = [],
    isExpanded: Bool = true
  ) {
    self.id = id
    self.semanticParentID = semanticParentID
    self.childPolicy = childPolicy
    self.childIDs = childIDs
    self.isExpanded = isExpanded
  }

  func replacing(childIDs: [NodeID]) -> Self {
    Self(
      id: id,
      semanticParentID: semanticParentID,
      childPolicy: childPolicy,
      childIDs: childIDs,
      isExpanded: isExpanded
    )
  }

  func replacing(isExpanded: Bool) -> Self {
    Self(
      id: id,
      semanticParentID: semanticParentID,
      childPolicy: childPolicy,
      childIDs: childIDs,
      isExpanded: isExpanded
    )
  }
}

extension SidebarCollectionNode: Sendable where NodeID: Sendable {}

/// An app-owned logical sidebar section. Native collection-view sections are
/// deliberately not part of this model.
public struct SidebarCollectionSection<
  NodeID: Hashable,
  SectionID: Hashable
>: Hashable {
  public let id: SectionID
  public let rootIDs: [NodeID]

  public init(id: SectionID, rootIDs: [NodeID]) {
    self.id = id
    self.rootIDs = rootIDs
  }

  func replacing(rootIDs: [NodeID]) -> Self {
    Self(id: id, rootIDs: rootIDs)
  }
}

extension SidebarCollectionSection: Sendable where NodeID: Sendable, SectionID: Sendable {}

/// A stable, identity-based insertion destination.
///
/// `beforeSiblingID == nil` means after the final sibling. A root slot has no
/// parent. A child slot always names the logical section inherited from its
/// parent so lane changes and hierarchy changes remain one atomic intent.
public struct SidebarCollectionSlot<
  NodeID: Hashable,
  SectionID: Hashable
>: Hashable {
  public let sectionID: SectionID
  public let parentID: NodeID?
  public let beforeSiblingID: NodeID?

  public init(
    sectionID: SectionID,
    parentID: NodeID?,
    beforeSiblingID: NodeID?
  ) {
    self.sectionID = sectionID
    self.parentID = parentID
    self.beforeSiblingID = beforeSiblingID
  }
}

extension SidebarCollectionSlot: Sendable where NodeID: Sendable, SectionID: Sendable {}

public struct SidebarCollectionProjectedNode<
  NodeID: Hashable,
  SectionID: Hashable
>: Hashable {
  public let id: NodeID
  public let sectionID: SectionID
  public let parentID: NodeID?
  public let depth: Int
}

extension SidebarCollectionProjectedNode: Sendable where NodeID: Sendable, SectionID: Sendable {}

/// Frozen membership for one internal reorder transaction.
///
/// `attachedNodeIDs` always contains the complete presentation subtree.
/// `visibleNodeIDs` respects collapse and therefore defines preview/slot height.
public struct SidebarCollectionDragGroup<NodeID: Hashable>: Hashable {
  public let sourceID: NodeID
  public let attachedNodeIDs: [NodeID]
  public let visibleNodeIDs: [NodeID]

  public init(
    sourceID: NodeID,
    attachedNodeIDs: [NodeID],
    visibleNodeIDs: [NodeID]
  ) {
    self.sourceID = sourceID
    self.attachedNodeIDs = attachedNodeIDs
    self.visibleNodeIDs = visibleNodeIDs
  }
}

extension SidebarCollectionDragGroup: Sendable where NodeID: Sendable {}

public enum SidebarCollectionModelError: Error, Equatable, Sendable {
  case duplicateSectionID
  case duplicateNodeID
  case missingNode
  case duplicatePlacement
  case unplacedNode
  case cycle
  case childrenNotAllowed
  case childRejectedByContainer
  case sourceMissing
  case destinationSectionMissing
  case destinationParentMissing
  case destinationSectionMismatch
  case destinationInsideDraggedGroup
  case invalidBeforeSibling
  case nodeIsNotAContainer
  case sourceOnlyMoveRequiresRoot
  case pendingMoveDependency
}

/// The single value authority for sidebar hierarchy and ordering.
public struct SidebarCollectionSnapshot<
  NodeID: Hashable,
  SectionID: Hashable
>: Equatable {
  public let sections: [SidebarCollectionSection<NodeID, SectionID>]
  public let nodes: [NodeID: SidebarCollectionNode<NodeID>]

  private let parentByNodeID: [NodeID: NodeID]
  private let sectionByNodeID: [NodeID: SectionID]

  /// A nonthrowing crash-safe fallback for a projection that rejected corrupt
  /// source data. Empty sections cannot violate placement or hierarchy rules.
  public init(emptySectionIDs: [SectionID]) {
    var seen = Set<SectionID>()
    sections = emptySectionIDs.compactMap { id in
      guard seen.insert(id).inserted else { return nil }
      return SidebarCollectionSection(id: id, rootIDs: [])
    }
    nodes = [:]
    parentByNodeID = [:]
    sectionByNodeID = [:]
  }

  public init(
    sections: [SidebarCollectionSection<NodeID, SectionID>],
    nodes: [SidebarCollectionNode<NodeID>]
  ) throws {
    guard Set(sections.map(\.id)).count == sections.count else {
      throw SidebarCollectionModelError.duplicateSectionID
    }

    let nodeByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard nodeByID.count == nodes.count else {
      throw SidebarCollectionModelError.duplicateNodeID
    }

    for node in nodes {
      if node.childPolicy == .none, node.childIDs.isEmpty == false {
        throw SidebarCollectionModelError.childrenNotAllowed
      }
      for childID in node.childIDs {
        guard let child = nodeByID[childID] else {
          throw SidebarCollectionModelError.missingNode
        }
        if node.childPolicy == .semanticParentOnly,
           child.semanticParentID != node.id {
          throw SidebarCollectionModelError.childRejectedByContainer
        }
      }
    }
    for section in sections where section.rootIDs.contains(where: { nodeByID[$0] == nil }) {
      throw SidebarCollectionModelError.missingNode
    }

    var visiting = Set<NodeID>()
    var visited = Set<NodeID>()
    func validateAcyclic(_ id: NodeID) throws {
      if visiting.contains(id) {
        throw SidebarCollectionModelError.cycle
      }
      guard visited.contains(id) == false, let node = nodeByID[id] else { return }
      visiting.insert(id)
      for childID in node.childIDs {
        try validateAcyclic(childID)
      }
      visiting.remove(id)
      visited.insert(id)
    }
    for id in nodeByID.keys {
      try validateAcyclic(id)
    }

    var placementCount: [NodeID: Int] = [:]
    for section in sections {
      for id in section.rootIDs {
        placementCount[id, default: 0] += 1
      }
    }
    for node in nodes {
      for id in node.childIDs {
        placementCount[id, default: 0] += 1
      }
    }
    guard placementCount.values.allSatisfy({ $0 == 1 }) else {
      throw SidebarCollectionModelError.duplicatePlacement
    }
    guard nodeByID.keys.allSatisfy({ placementCount[$0] == 1 }) else {
      throw SidebarCollectionModelError.unplacedNode
    }

    var parents: [NodeID: NodeID] = [:]
    for node in nodes {
      for childID in node.childIDs {
        parents[childID] = node.id
      }
    }

    var sectionByNode: [NodeID: SectionID] = [:]
    func assignSection(_ sectionID: SectionID, to id: NodeID) {
      sectionByNode[id] = sectionID
      for childID in nodeByID[id]?.childIDs ?? [] {
        assignSection(sectionID, to: childID)
      }
    }
    for section in sections {
      for rootID in section.rootIDs {
        assignSection(section.id, to: rootID)
      }
    }

    self.sections = sections
    self.nodes = nodeByID
    parentByNodeID = parents
    sectionByNodeID = sectionByNode
  }

  public func parentID(of nodeID: NodeID) -> NodeID? {
    parentByNodeID[nodeID]
  }

  public func sectionID(containing nodeID: NodeID) -> SectionID? {
    sectionByNodeID[nodeID]
  }

  public func visibleProjection() -> [SidebarCollectionProjectedNode<NodeID, SectionID>] {
    var result: [SidebarCollectionProjectedNode<NodeID, SectionID>] = []
    func append(_ id: NodeID, sectionID: SectionID, parentID: NodeID?, depth: Int) {
      guard let node = nodes[id] else { return }
      result.append(SidebarCollectionProjectedNode(
        id: id,
        sectionID: sectionID,
        parentID: parentID,
        depth: depth
      ))
      guard node.isExpanded else { return }
      for childID in node.childIDs {
        append(childID, sectionID: sectionID, parentID: id, depth: depth + 1)
      }
    }
    for section in sections {
      for rootID in section.rootIDs {
        append(rootID, sectionID: section.id, parentID: nil, depth: 0)
      }
    }
    return result
  }

  public func dragGroup(for sourceID: NodeID) throws -> SidebarCollectionDragGroup<NodeID> {
    guard nodes[sourceID] != nil else {
      throw SidebarCollectionModelError.sourceMissing
    }

    var attached: [NodeID] = []
    func appendAttached(_ id: NodeID) {
      guard let node = nodes[id] else { return }
      attached.append(id)
      node.childIDs.forEach(appendAttached)
    }
    var visible: [NodeID] = []
    func appendVisible(_ id: NodeID) {
      guard let node = nodes[id] else { return }
      visible.append(id)
      guard node.isExpanded else { return }
      node.childIDs.forEach(appendVisible)
    }
    appendAttached(sourceID)
    appendVisible(sourceID)
    return SidebarCollectionDragGroup(
      sourceID: sourceID,
      attachedNodeIDs: attached,
      visibleNodeIDs: visible
    )
  }

  /// Returns every currently reachable structural destination for `sourceID`.
  /// Source subtree IDs are removed first, so the result contains one logical
  /// destination reservation and never retains the original source span.
  public func legalSlots(
    for sourceID: NodeID
  ) throws -> [SidebarCollectionSlot<NodeID, SectionID>] {
    guard let source = nodes[sourceID] else {
      throw SidebarCollectionModelError.sourceMissing
    }
    let group = try dragGroup(for: sourceID)
    let excluded = Set(group.attachedNodeIDs)
    var result: [SidebarCollectionSlot<NodeID, SectionID>] = []

    for section in sections {
      let roots = section.rootIDs.filter { excluded.contains($0) == false }
      result.append(contentsOf: slots(
        sectionID: section.id,
        parentID: nil,
        siblingIDs: roots
      ))
    }

    for projectedNode in visibleProjection() where excluded.contains(projectedNode.id) == false {
      guard let parent = nodes[projectedNode.id],
            accepts(source, in: parent)
      else { continue }
      let children = parent.childIDs.filter { excluded.contains($0) == false }
      if parent.isExpanded || children.isEmpty {
        result.append(contentsOf: slots(
          sectionID: projectedNode.sectionID,
          parentID: parent.id,
          siblingIDs: children
        ))
      } else {
        // Hidden siblings have no measurable between-row guides. The parent
        // itself still provides one deterministic append destination so a
        // detached reply can reattach without forcing expansion first.
        result.append(SidebarCollectionSlot(
          sectionID: projectedNode.sectionID,
          parentID: parent.id,
          beforeSiblingID: nil
        ))
      }
    }
    return result
  }

  public func currentSlot(
    for sourceID: NodeID
  ) throws -> SidebarCollectionSlot<NodeID, SectionID> {
    guard nodes[sourceID] != nil else {
      throw SidebarCollectionModelError.sourceMissing
    }
    guard let sectionID = sectionByNodeID[sourceID] else {
      throw SidebarCollectionModelError.destinationSectionMissing
    }
    let parentID = parentByNodeID[sourceID]
    let siblings: [NodeID]
    if let parentID {
      guard let parent = nodes[parentID] else {
        throw SidebarCollectionModelError.destinationParentMissing
      }
      siblings = parent.childIDs
    } else {
      guard let section = sections.first(where: { $0.id == sectionID }) else {
        throw SidebarCollectionModelError.destinationSectionMissing
      }
      siblings = section.rootIDs
    }
    guard let index = siblings.firstIndex(of: sourceID) else {
      throw SidebarCollectionModelError.sourceMissing
    }
    let beforeID = siblings.indices.contains(index + 1) ? siblings[index + 1] : nil
    return SidebarCollectionSlot(
      sectionID: sectionID,
      parentID: parentID,
      beforeSiblingID: beforeID
    )
  }

  public func isNode(
    _ sourceID: NodeID,
    at slot: SidebarCollectionSlot<NodeID, SectionID>
  ) -> Bool {
    (try? currentSlot(for: sourceID)) == slot
  }

  /// Applies one atomic reorder/reparent intent. The moved node retains its
  /// complete attached subtree, so moving a parent can never strand a reply.
  public func moving(
    _ sourceID: NodeID,
    to destination: SidebarCollectionSlot<NodeID, SectionID>,
    scope: SidebarCollectionMoveScope = .attachedSubtree
  ) throws -> Self {
    guard let source = nodes[sourceID] else {
      throw SidebarCollectionModelError.sourceMissing
    }
    guard sections.contains(where: { $0.id == destination.sectionID }) else {
      throw SidebarCollectionModelError.destinationSectionMissing
    }
    if scope == .sourceOnly, source.childIDs.isEmpty == false {
      guard parentByNodeID[sourceID] == nil,
            let currentSectionID = sectionByNodeID[sourceID],
            let sectionIndex = sections.firstIndex(where: { $0.id == currentSectionID })
      else {
        throw SidebarCollectionModelError.sourceOnlyMoveRequiresRoot
      }

      var promotedSections = sections
      let section = promotedSections[sectionIndex]
      guard let sourceIndex = section.rootIDs.firstIndex(of: sourceID) else {
        throw SidebarCollectionModelError.sourceMissing
      }
      var promotedRoots = section.rootIDs
      promotedRoots.insert(contentsOf: source.childIDs, at: sourceIndex + 1)
      promotedSections[sectionIndex] = section.replacing(rootIDs: promotedRoots)

      var promotedNodes = nodes
      promotedNodes[sourceID] = source.replacing(childIDs: [])
      let promoted = try Self(
        sections: promotedSections,
        nodes: Array(promotedNodes.values)
      )
      return try promoted.moving(
        sourceID,
        to: destination,
        scope: .attachedSubtree
      )
    }

    let group = try dragGroup(for: sourceID)
    let groupIDs = Set(group.attachedNodeIDs)
    if let parentID = destination.parentID, groupIDs.contains(parentID) {
      throw SidebarCollectionModelError.destinationInsideDraggedGroup
    }
    if let beforeID = destination.beforeSiblingID, groupIDs.contains(beforeID) {
      throw SidebarCollectionModelError.destinationInsideDraggedGroup
    }

    var nextSections = sections
    var nextNodes = nodes

    if let currentParentID = parentByNodeID[sourceID] {
      guard let parent = nextNodes[currentParentID] else {
        throw SidebarCollectionModelError.missingNode
      }
      nextNodes[currentParentID] = parent.replacing(
        childIDs: parent.childIDs.filter { $0 != sourceID }
      )
    } else {
      guard let currentSectionID = sectionByNodeID[sourceID],
            let sectionIndex = nextSections.firstIndex(where: { $0.id == currentSectionID })
      else {
        throw SidebarCollectionModelError.destinationSectionMissing
      }
      let section = nextSections[sectionIndex]
      nextSections[sectionIndex] = section.replacing(
        rootIDs: section.rootIDs.filter { $0 != sourceID }
      )
    }

    if let parentID = destination.parentID {
      guard let parent = nextNodes[parentID] else {
        throw SidebarCollectionModelError.destinationParentMissing
      }
      guard sectionByNodeID[parentID] == destination.sectionID else {
        throw SidebarCollectionModelError.destinationSectionMismatch
      }
      guard accepts(source, in: parent) else {
        throw SidebarCollectionModelError.childRejectedByContainer
      }
      var siblings = parent.childIDs.filter { $0 != sourceID }
      let insertionIndex = try insertionIndex(
        before: destination.beforeSiblingID,
        in: siblings
      )
      siblings.insert(sourceID, at: insertionIndex)
      nextNodes[parentID] = parent.replacing(childIDs: siblings)
    } else {
      guard let sectionIndex = nextSections.firstIndex(where: {
        $0.id == destination.sectionID
      }) else {
        throw SidebarCollectionModelError.destinationSectionMissing
      }
      let section = nextSections[sectionIndex]
      var siblings = section.rootIDs.filter { $0 != sourceID }
      let insertionIndex = try insertionIndex(
        before: destination.beforeSiblingID,
        in: siblings
      )
      siblings.insert(sourceID, at: insertionIndex)
      nextSections[sectionIndex] = section.replacing(rootIDs: siblings)
    }

    return try Self(sections: nextSections, nodes: Array(nextNodes.values))
  }

  public func settingExpanded(_ isExpanded: Bool, for nodeID: NodeID) throws -> Self {
    guard let node = nodes[nodeID] else {
      throw SidebarCollectionModelError.sourceMissing
    }
    guard node.childPolicy != .none else {
      throw SidebarCollectionModelError.nodeIsNotAContainer
    }
    var nextNodes = nodes
    nextNodes[nodeID] = node.replacing(isExpanded: isExpanded)
    return try Self(sections: sections, nodes: Array(nextNodes.values))
  }

  private func slots(
    sectionID: SectionID,
    parentID: NodeID?,
    siblingIDs: [NodeID]
  ) -> [SidebarCollectionSlot<NodeID, SectionID>] {
    siblingIDs.map { beforeID in
      SidebarCollectionSlot(
        sectionID: sectionID,
        parentID: parentID,
        beforeSiblingID: beforeID
      )
    } + [SidebarCollectionSlot(
      sectionID: sectionID,
      parentID: parentID,
      beforeSiblingID: nil
    )]
  }

  private func accepts(
    _ child: SidebarCollectionNode<NodeID>,
    in parent: SidebarCollectionNode<NodeID>
  ) -> Bool {
    switch parent.childPolicy {
    case .none:
      false
    case .semanticParentOnly:
      child.semanticParentID == parent.id
    case .any:
      true
    }
  }

  private func insertionIndex(
    before siblingID: NodeID?,
    in siblings: [NodeID]
  ) throws -> Int {
    guard let siblingID else { return siblings.count }
    guard let index = siblings.firstIndex(of: siblingID) else {
      throw SidebarCollectionModelError.invalidBeforeSibling
    }
    return index
  }
}

extension SidebarCollectionSnapshot: Sendable where NodeID: Sendable, SectionID: Sendable {}

public struct SidebarCollectionSlotGuide<
  NodeID: Hashable,
  SectionID: Hashable
>: Hashable {
  public let slot: SidebarCollectionSlot<NodeID, SectionID>
  public let position: Double

  public init(slot: SidebarCollectionSlot<NodeID, SectionID>, position: Double) {
    self.slot = slot
    self.position = position
  }
}

extension SidebarCollectionSlotGuide: Sendable where NodeID: Sendable, SectionID: Sendable {}

/// Value-only outline geometry shared by the AppKit slot builder and tests.
/// `nil` depths represent structural rows and terminate the current subtree.
public enum SidebarCollectionVisibleOutline {
  public static func indexAfterSubtree(
    startingAt start: Int,
    depths: [Int?]
  ) -> Int {
    guard depths.indices.contains(start), let rootDepth = depths[start] else {
      return min(max(start + 1, 0), depths.count)
    }
    var cursor = start + 1
    while depths.indices.contains(cursor),
          let depth = depths[cursor],
          depth > rootDepth {
      cursor += 1
    }
    return cursor
  }
}

/// Pure stable-ID pointer resolver. The current slot wins ties and remains
/// selected until another guide is closer by more than `hysteresis`.
public enum SidebarCollectionSlotResolver {
  public static func resolve<
    NodeID: Hashable,
    SectionID: Hashable
  >(
    position: Double,
    guides: [SidebarCollectionSlotGuide<NodeID, SectionID>],
    currentSlot: SidebarCollectionSlot<NodeID, SectionID>?,
    hysteresis: Double = 0
  ) -> SidebarCollectionSlot<NodeID, SectionID>? {
    guard guides.isEmpty == false else { return nil }
    let currentGuide = currentSlot.flatMap { current in
      guides.first(where: { $0.slot == current })
    }

    var best = guides[0]
    var bestDistance = abs(position - best.position)
    for guide in guides.dropFirst() {
      let distance = abs(position - guide.position)
      if distance < bestDistance {
        best = guide
        bestDistance = distance
      } else if distance == bestDistance,
                guide.slot == currentSlot,
                best.slot != currentSlot {
        best = guide
      }
    }

    guard let currentSlot, let currentGuide, best.slot != currentSlot else {
      return best.slot
    }
    let currentDistance = abs(position - currentGuide.position)
    if bestDistance + max(hysteresis, 0) >= currentDistance {
      return currentSlot
    }
    return best.slot
  }
}

public struct SidebarCollectionPendingMove<
  NodeID: Hashable,
  SectionID: Hashable
>: Equatable {
  public let id: UUID
  public let sourceID: NodeID
  public let destination: SidebarCollectionSlot<NodeID, SectionID>
  public let scope: SidebarCollectionMoveScope
  public let rpcAcknowledged: Bool

  public init(
    id: UUID,
    sourceID: NodeID,
    destination: SidebarCollectionSlot<NodeID, SectionID>,
    scope: SidebarCollectionMoveScope = .attachedSubtree,
    rpcAcknowledged: Bool = false
  ) {
    self.id = id
    self.sourceID = sourceID
    self.destination = destination
    self.scope = scope
    self.rpcAcknowledged = rpcAcknowledged
  }

  func acknowledgingRPC() -> Self {
    Self(
      id: id,
      sourceID: sourceID,
      destination: destination,
      scope: scope,
      rpcAcknowledged: true
    )
  }
}

extension SidebarCollectionPendingMove: Sendable where NodeID: Sendable, SectionID: Sendable {}

public struct SidebarCollectionReconciliation: Equatable, Sendable {
  public let acknowledgedMoveIDs: [UUID]
  public let cancelledMoveIDs: [UUID]
  public let presentationChanged: Bool
}

/// Value-only optimistic reconciliation. RPC success never moves rows a second
/// time; matching observations acknowledge silently, while failure or missing
/// identity recomputes the presentation exactly once from the latest base.
public struct SidebarCollectionOptimisticState<
  NodeID: Hashable,
  SectionID: Hashable
>: Equatable {
  public private(set) var confirmed: SidebarCollectionSnapshot<NodeID, SectionID>
  public private(set) var presented: SidebarCollectionSnapshot<NodeID, SectionID>
  public private(set) var pendingMoves: [SidebarCollectionPendingMove<NodeID, SectionID>]

  public init(confirmed: SidebarCollectionSnapshot<NodeID, SectionID>) {
    self.confirmed = confirmed
    presented = confirmed
    pendingMoves = []
  }

  /// Adds a move, coalescing any older pending intent for the same source.
  /// A newer same-source intent is rejected if another pending move depends on
  /// the presentation it would replace; an in-flight RPC cannot be cancelled
  /// safely, so silently dropping that dependency would diverge from storage.
  @discardableResult
  public mutating func beginMove(
    id: UUID,
    sourceID: NodeID,
    destination: SidebarCollectionSlot<NodeID, SectionID>,
    scope: SidebarCollectionMoveScope = .attachedSubtree
  ) throws -> Bool {
    let previousPresentation = presented
    let replacesPendingSource = pendingMoves.contains { $0.sourceID == sourceID }
    let retained = pendingMoves.filter { $0.sourceID != sourceID }
    let replayed = replay(retained, on: confirmed)
    guard replayed.moves.count == retained.count else {
      throw SidebarCollectionModelError.pendingMoveDependency
    }
    var nextPending = replayed.moves
    let moved = try replayed.snapshot.moving(sourceID, to: destination, scope: scope)
    if moved != replayed.snapshot || replacesPendingSource {
      nextPending.append(SidebarCollectionPendingMove(
        id: id,
        sourceID: sourceID,
        destination: destination,
        scope: scope
      ))
    }
    pendingMoves = nextPending
    presented = moved
    return presented != previousPresentation
  }

  /// Records RPC success without changing the presentation. The matching model
  /// observation remains the authority that removes the pending intent.
  @discardableResult
  public mutating func acknowledgeRPC(id: UUID) -> Bool {
    guard let index = pendingMoves.firstIndex(where: { $0.id == id }) else {
      return false
    }
    pendingMoves[index] = pendingMoves[index].acknowledgingRPC()
    let replayed = replay(pendingMoves, on: confirmed, removesAcknowledgedMatches: true)
    pendingMoves = replayed.moves
    presented = replayed.snapshot
    return true
  }

  /// Rolls back a matching failed intent against the newest confirmed model.
  /// Stale failures are ignored and therefore cannot undo a newer move.
  @discardableResult
  public mutating func failMove(id: UUID) -> Bool {
    guard pendingMoves.contains(where: { $0.id == id }) else { return false }
    let previousPresentation = presented
    pendingMoves.removeAll(where: { $0.id == id })
    let replayed = replay(pendingMoves, on: confirmed)
    pendingMoves = replayed.moves
    presented = replayed.snapshot
    return presented != previousPresentation
  }

  /// Rebases pending intents over the latest model snapshot. Already-applied
  /// intents acknowledge; intents whose source/destination disappeared cancel.
  @discardableResult
  public mutating func receiveExternal(
    _ snapshot: SidebarCollectionSnapshot<NodeID, SectionID>
  ) -> SidebarCollectionReconciliation {
    let previousPresentation = presented
    confirmed = snapshot
    var cursor = snapshot
    var retained: [SidebarCollectionPendingMove<NodeID, SectionID>] = []
    var acknowledged: [UUID] = []
    var cancelled: [UUID] = []

    for move in pendingMoves {
      if move.rpcAcknowledged,
         cursor.isNode(move.sourceID, at: move.destination) {
        acknowledged.append(move.id)
        continue
      }
      do {
        cursor = try cursor.moving(
          move.sourceID,
          to: move.destination,
          scope: move.scope
        )
        retained.append(move)
      } catch {
        cancelled.append(move.id)
      }
    }

    pendingMoves = retained
    presented = cursor
    return SidebarCollectionReconciliation(
      acknowledgedMoveIDs: acknowledged,
      cancelledMoveIDs: cancelled,
      presentationChanged: presented != previousPresentation
    )
  }

  private func replay(
    _ moves: [SidebarCollectionPendingMove<NodeID, SectionID>],
    on snapshot: SidebarCollectionSnapshot<NodeID, SectionID>,
    removesAcknowledgedMatches: Bool = false
  ) -> (
    snapshot: SidebarCollectionSnapshot<NodeID, SectionID>,
    moves: [SidebarCollectionPendingMove<NodeID, SectionID>]
  ) {
    var cursor = snapshot
    var retained: [SidebarCollectionPendingMove<NodeID, SectionID>] = []
    for move in moves {
      if removesAcknowledgedMatches,
         move.rpcAcknowledged,
         cursor.isNode(move.sourceID, at: move.destination) {
        continue
      }
      guard let moved = try? cursor.moving(
        move.sourceID,
        to: move.destination,
        scope: move.scope
      ) else {
        continue
      }
      cursor = moved
      retained.append(move)
    }
    return (cursor, retained)
  }
}

extension SidebarCollectionOptimisticState: Sendable where NodeID: Sendable, SectionID: Sendable {}
