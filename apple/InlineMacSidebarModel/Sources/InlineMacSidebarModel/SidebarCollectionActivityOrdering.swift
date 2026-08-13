/// Cached ordering for trees whose root position follows the newest activity
/// in the complete attached subtree.
public struct SidebarCollectionActivityOrdering<
  NodeID: Hashable,
  Activity: Comparable
> {
  private let subtreeActivityByID: [NodeID: Activity]
  private let stableIndexByID: [NodeID: Int]

  public init(
    childrenByParentID: [NodeID: [NodeID]],
    activityByNodeID: [NodeID: Activity],
    stableIDs: [NodeID]
  ) {
    stableIndexByID = Dictionary(
      uniqueKeysWithValues: stableIDs.enumerated().map { ($0.element, $0.offset) }
    )
    var cached: [NodeID: Activity] = [:]
    var visiting = Set<NodeID>()

    func resolve(_ id: NodeID) -> Activity? {
      if let cachedActivity = cached[id] { return cachedActivity }
      guard visiting.insert(id).inserted else { return activityByNodeID[id] }
      var result = activityByNodeID[id]
      for childID in childrenByParentID[id] ?? [] {
        guard let childActivity = resolve(childID) else { continue }
        result = result.map { max($0, childActivity) } ?? childActivity
      }
      visiting.remove(id)
      if let result {
        cached[id] = result
      }
      return result
    }

    for id in stableIDs {
      _ = resolve(id)
    }
    subtreeActivityByID = cached
  }

  public func ordered(_ ids: [NodeID]) -> [NodeID] {
    ids.sorted { lhs, rhs in
      switch (subtreeActivityByID[lhs], subtreeActivityByID[rhs]) {
      case let (lhsActivity?, rhsActivity?) where lhsActivity != rhsActivity:
        lhsActivity > rhsActivity
      case (_?, nil):
        true
      case (nil, _?):
        false
      default:
        (stableIndexByID[lhs] ?? .max) < (stableIndexByID[rhs] ?? .max)
      }
    }
  }

  public func subtreeActivity(for id: NodeID) -> Activity? {
    subtreeActivityByID[id]
  }
}
