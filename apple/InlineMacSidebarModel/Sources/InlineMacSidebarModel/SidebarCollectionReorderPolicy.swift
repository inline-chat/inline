/// Product-level permissions applied before proposal construction and again at
/// the persistence boundary.
public enum SidebarCollectionReorderPolicy: Equatable, Sendable {
  case manual
  case pinningOnly

  public func allowsMove(
    sourceIsRoot: Bool,
    changesSection: Bool,
    changesParent: Bool,
    entersPinnedContainer: Bool = false
  ) -> Bool {
    switch self {
    case .manual:
      true
    case .pinningOnly:
      entersPinnedContainer || (sourceIsRoot && changesSection && changesParent == false)
    }
  }
}
