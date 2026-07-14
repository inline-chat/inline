import Foundation

/// Bounds cancellation-insensitive provider work without pretending Swift can
/// forcibly destroy an SDK or Core Audio await that never returns.
///
/// The owner records an operation only after its logical deadline fires. A
/// late return removes that operation and can close the circuit. The small
/// `returnedBeforeAbandonment` set resolves the race where the provider returns
/// just after the timeout wins but before the actor records the abandonment.
struct GridOperationCircuitBreaker: Sendable {
  let limit: Int

  private(set) var abandonedOperations: [UUID: String] = [:]
  private var returnedBeforeAbandonment = Set<UUID>()

  init(limit: Int) {
    self.limit = max(limit, 1)
  }

  var abandonedOperationCount: Int {
    abandonedOperations.count
  }

  var isOpen: Bool {
    abandonedOperationCount >= limit
  }

  func contains(id: UUID) -> Bool {
    abandonedOperations[id] != nil
  }

  /// Returns true when this operation remains abandoned after accounting for
  /// a return that may have raced ahead of actor-side timeout handling.
  @discardableResult
  mutating func abandon(id: UUID, operation: String) -> Bool {
    if returnedBeforeAbandonment.remove(id) != nil {
      return false
    }
    abandonedOperations[id] = operation
    return true
  }

  /// Returns true when a tracked abandoned operation was released.
  @discardableResult
  mutating func retiredOperationReturned(id: UUID) -> Bool {
    if abandonedOperations.removeValue(forKey: id) != nil {
      return true
    }
    returnedBeforeAbandonment.insert(id)
    return false
  }
}
