/// What a store knows about one requested ID.
public enum ObjectState: Sendable, Equatable {
  /// Read from the source and kept current by the host's write notifications.
  case fresh
  /// A previously read value. A revalidation is already scheduled.
  case stale
  /// The source has no such record.
  case missing
  /// Never read. Use `load` or `warm`, or `get` when the first frame needs it.
  case unloaded
}

/// The answer to one store request: immutable copies plus the state of each
/// requested ID, so a view can decide whether to wait for `changes`.
public struct ObjectStoreSnapshot<ID: Hashable & Sendable, Record: Sendable>: Sendable {
  var records: [ID: Record] = [:]
  var states: [ID: ObjectState] = [:]

  public func record(_ id: ID) -> Record? {
    records[id]
  }

  public func state(of id: ID) -> ObjectState {
    states[id] ?? .unloaded
  }
}
