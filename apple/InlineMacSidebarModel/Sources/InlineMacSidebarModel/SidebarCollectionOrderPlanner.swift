import Foundation

/// Validates the two persisted neighbors around a moved sidebar item before
/// asking the caller's fractional-index implementation for a new key.
///
/// Each moved dialog receives one new key. Batch moves allocate consecutive
/// keys in the same outside gap. Missing, duplicate, or reversed neighbor keys
/// are rejected instead of triggering a client-side lane renumber.
public enum SidebarCollectionOrderPlanner {
  public static func insertionOrder(
    hasPrevious: Bool,
    previousOrder: String?,
    hasNext: Bool,
    nextOrder: String?,
    between: (String?, String?) -> String
  ) -> String? {
    guard hasPrevious == (previousOrder != nil),
          hasNext == (nextOrder != nil)
    else { return nil }

    if let previousOrder, let nextOrder, previousOrder >= nextOrder {
      return nil
    }

    return between(previousOrder, nextOrder)
  }
}
