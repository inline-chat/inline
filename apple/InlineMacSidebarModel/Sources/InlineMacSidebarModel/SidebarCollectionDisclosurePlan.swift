/// Identity-only plan for one disclosure whose expanded membership differs by
/// one contiguous block immediately after a stable owner row.
///
/// Geometry and animation remain platform-owned. Keeping this validation in
/// the dependency-free model prevents a section header and a nested parent
/// from developing separate transition rules.
public struct SidebarCollectionDisclosurePlan<ID: Hashable>: Equatable {
  public let ownerID: ID
  public let expandedIDs: [ID]
  public let collapsedIDs: [ID]
  public let affectedIDs: [ID]
  public let trailingIDs: [ID]

  public init?(
    expandedIDs: [ID],
    collapsedIDs: [ID],
    ownerID: ID
  ) {
    let expandedSet = Set(expandedIDs)
    let collapsedSet = Set(collapsedIDs)
    guard expandedSet.count == expandedIDs.count,
          collapsedSet.count == collapsedIDs.count,
          expandedSet.isSuperset(of: collapsedSet),
          let ownerIndex = expandedIDs.firstIndex(of: ownerID),
          collapsedSet.contains(ownerID)
    else { return nil }

    let affectedIDs = expandedIDs.filter { collapsedSet.contains($0) == false }
    guard affectedIDs.isEmpty == false else { return nil }

    let affectedSet = Set(affectedIDs)
    let affectedIndices = expandedIDs.indices.filter {
      affectedSet.contains(expandedIDs[$0])
    }
    guard affectedIndices.first == ownerIndex + 1,
          zip(affectedIndices, affectedIndices.dropFirst()).allSatisfy({ lhs, rhs in
            rhs == lhs + 1
          }),
          expandedIDs.filter({ affectedSet.contains($0) == false }) == collapsedIDs,
          let lastAffectedIndex = affectedIndices.last
    else { return nil }

    self.ownerID = ownerID
    self.expandedIDs = expandedIDs
    self.collapsedIDs = collapsedIDs
    self.affectedIDs = affectedIDs
    trailingIDs = Array(expandedIDs.suffix(from: lastAffectedIndex + 1))
  }
}

extension SidebarCollectionDisclosurePlan: Sendable where ID: Sendable {}

/// Pure timing projection for one row under the disclosure's shared boundary.
///
/// A basic zero-to-full mask animation is not equivalent to a shared clip:
/// it starts revealing every row at once. These progress stops let the render
/// layer hold a row hidden until the boundary reaches it, reveal it while the
/// boundary crosses it, then hold it fully visible.
public enum SidebarCollectionDisclosureTimeline {
  public static func visibleFraction(
    progress: Double,
    rowStart: Double,
    rowEnd: Double
  ) -> Double {
    guard rowEnd > rowStart else { return progress >= rowEnd ? 1 : 0 }
    return min(max((progress - rowStart) / (rowEnd - rowStart), 0), 1)
  }

  public static func keyProgresses(
    from start: Double,
    to target: Double,
    rowStart: Double,
    rowEnd: Double
  ) -> [Double] {
    guard start != target else { return [start] }
    let lower = min(start, target)
    let upper = max(start, target)
    let crossings = [rowStart, rowEnd]
      .filter { $0 > lower && $0 < upper }
      .sorted { lhs, rhs in start < target ? lhs < rhs : lhs > rhs }
    return [start] + crossings + [target]
  }
}
