/// Transient chat selection in visible sidebar order. Navigation remains owned
/// by the caller; modifier clicks only change this value.
public struct SidebarCollectionSelection<ID: Hashable>: Equatable {
  public private(set) var selectedIDs: Set<ID>
  public private(set) var anchorID: ID?

  public init(selectedIDs: Set<ID> = [], anchorID: ID? = nil) {
    self.selectedIDs = selectedIDs
    self.anchorID = anchorID
  }

  public mutating func click(_ id: ID, orderedIDs: [ID], command: Bool, shift: Bool) {
    guard orderedIDs.contains(id) else { return }
    if shift, let anchorID,
       let start = orderedIDs.firstIndex(of: anchorID),
       let end = orderedIDs.firstIndex(of: id)
    {
      let range = Set(orderedIDs[min(start, end) ... max(start, end)])
      selectedIDs = command ? selectedIDs.union(range) : range
    } else if command {
      if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
      anchorID = id
    } else {
      selectedIDs = [id]
      anchorID = id
    }
  }

  public mutating func retainVisible(_ orderedIDs: [ID]) {
    let visible = Set(orderedIDs)
    selectedIDs.formIntersection(visible)
    if let anchorID, !visible.contains(anchorID) {
      self.anchorID = orderedIDs.first(where: selectedIDs.contains)
    }
  }
}

extension SidebarCollectionSelection: Sendable where ID: Sendable {}
