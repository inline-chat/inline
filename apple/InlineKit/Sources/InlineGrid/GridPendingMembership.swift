/// The membership change this process is waiting on, so interfaces can show
/// joining, moving and leaving rather than one busy flag.
public enum GridPendingMembership: Equatable, Sendable {
  /// Joining a new room; the server assigns its id.
  case create(spaceID: Int64)
  case join(spaceID: Int64, roomID: Int64)
  /// Moving the user's call to this device, or resuming it here.
  case move(spaceID: Int64, roomID: Int64)
  case leave(spaceID: Int64)

  public var spaceID: Int64 {
    switch self {
      case let .create(spaceID), let .join(spaceID, _), let .move(spaceID, _), let .leave(spaceID): spaceID
    }
  }

  /// Joining a room or making one, as opposed to moving a call or leaving.
  public var isJoining: Bool {
    switch self {
      case .create, .join: true
      case .move, .leave: false
    }
  }
}
