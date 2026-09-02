/// Product-level permissions applied before proposal construction and again at
/// the persistence boundary.
public enum SidebarCollectionReorderPolicy: Equatable, Sendable {
  case manual
  case pinningOnly

  public func allowsMove(
    sourceIsRoot: Bool,
    changesSection: Bool,
    changesParent: Bool,
    changesFolderMembership: Bool = false,
    reordersPinnedLane: Bool = false
  ) -> Bool {
    switch self {
    case .manual:
      true
    case .pinningOnly:
      changesFolderMembership
        || (reordersPinnedLane && sourceIsRoot && changesParent == false)
        || (sourceIsRoot && changesSection && changesParent == false)
    }
  }

  public func allowsFolderMove(
    changesSection: Bool,
    reordersStableLane: Bool
  ) -> Bool {
    switch self {
    case .manual:
      true
    case .pinningOnly:
      changesSection || reordersStableLane
    }
  }
}
