/// Matches author decorations by surviving message identity. A merge keeps
/// the avatar that owned the new group's edge; a split keeps the old avatar
/// with the child that still contains its former owner.
public struct TimelineAvatarGroup<ID: Hashable & Sendable>: Sendable {
  public let memberIDs: [ID]
  public let ownerID: ID
  public let authorID: Int64

  public init(memberIDs: [ID], ownerID: ID, authorID: Int64) {
    self.memberIDs = memberIDs
    self.ownerID = ownerID
    self.authorID = authorID
  }
}

public enum TimelineAvatarGroupMatcher {
  private struct Edge {
    let old: Int
    let new: Int
    let overlap: Int
    let keepsNewOwner: Bool
    let keepsOldOwner: Bool
  }

  /// Returns one old group for each matched new group. Each old group is used
  /// at most once; unmatched old groups can fade while unmatched new groups
  /// can appear on the same presentation clock.
  public static func matches<ID: Hashable & Sendable>(
    old: [TimelineAvatarGroup<ID>], new: [TimelineAvatarGroup<ID>]
  ) -> [Int: Int] {
    var oldByMember: [ID: Int] = [:]
    for (index, group) in old.enumerated() {
      for id in group.memberIDs {
        oldByMember[id] = index
      }
    }
    var edges: [Edge] = []
    for (newIndex, group) in new.enumerated() {
      var overlapCounts: [Int: Int] = [:]
      for id in group.memberIDs {
        if let oldIndex = oldByMember[id], old[oldIndex].authorID == group.authorID {
          overlapCounts[oldIndex, default: 0] += 1
        }
      }
      for (oldIndex, count) in overlapCounts {
        edges.append(.init(
          old: oldIndex, new: newIndex, overlap: count,
          keepsNewOwner: oldByMember[group.ownerID] == oldIndex,
          keepsOldOwner: group.memberIDs.contains(old[oldIndex].ownerID)
        ))
      }
    }
    edges.sort { lhs, rhs in
      let leftBoth = lhs.keepsNewOwner && lhs.keepsOldOwner
      let rightBoth = rhs.keepsNewOwner && rhs.keepsOldOwner
      if leftBoth != rightBoth {
        return leftBoth
      }
      if lhs.keepsNewOwner != rhs.keepsNewOwner {
        return lhs.keepsNewOwner
      }
      if lhs.keepsOldOwner != rhs.keepsOldOwner {
        return lhs.keepsOldOwner
      }
      if lhs.overlap != rhs.overlap {
        return lhs.overlap > rhs.overlap
      }
      if lhs.new != rhs.new {
        return lhs.new < rhs.new
      }
      return lhs.old < rhs.old
    }
    var usedOld = Set<Int>()
    var usedNew = Set<Int>()
    var result: [Int: Int] = [:]
    for edge in edges where !usedOld.contains(edge.old) && !usedNew.contains(edge.new) {
      result[edge.new] = edge.old
      usedOld.insert(edge.old)
      usedNew.insert(edge.new)
    }
    return result
  }
}
