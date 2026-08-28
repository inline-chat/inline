import Foundation

/// Account-local Home visibility choices. Only stable space IDs are persisted;
/// names continue to come from the observed space list.
public struct HomeSpaceExclusions: Equatable, Sendable {
  public static let empty = Self(spaceIDs: [])

  public let spaceIDs: Set<Int64>

  public init(spaceIDs: Set<Int64>) {
    self.spaceIDs = spaceIDs
  }

  public init(rawValue: String) {
    spaceIDs = Set(rawValue.split(separator: ",").compactMap { Int64($0) })
  }

  public var rawValue: String {
    spaceIDs.sorted().map(String.init).joined(separator: ",")
  }

  public var isEmpty: Bool {
    spaceIDs.isEmpty
  }

  public func contains(_ spaceID: Int64) -> Bool {
    spaceIDs.contains(spaceID)
  }

  public func toggling(_ spaceID: Int64) -> Self {
    var next = spaceIDs
    if next.remove(spaceID) == nil {
      next.insert(spaceID)
    }
    return Self(spaceIDs: next)
  }

  public func includesInHome(spaceID: Int64?) -> Bool {
    guard let spaceID else { return true }
    return contains(spaceID) == false
  }
}
