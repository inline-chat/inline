/// Stable edge placement for roots that do not yet have a persisted order.
public enum SidebarCollectionRootOrdering {
  public static func anchoring<NodeID: Hashable>(
    _ anchoredIDs: Set<NodeID>,
    atStart: Bool,
    in orderedIDs: [NodeID]
  ) -> [NodeID] {
    guard anchoredIDs.isEmpty == false else { return orderedIDs }

    let anchored = orderedIDs.filter(anchoredIDs.contains)
    guard anchored.isEmpty == false else { return orderedIDs }

    let remaining = orderedIDs.filter { anchoredIDs.contains($0) == false }
    return atStart ? anchored + remaining : remaining + anchored
  }
}
