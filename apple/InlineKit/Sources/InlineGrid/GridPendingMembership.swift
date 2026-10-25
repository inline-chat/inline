/// The membership change this process is waiting on, so interfaces can show
/// joining, moving and leaving rather than one busy flag.
public enum GridPendingMembership: Equatable, Sendable {
  /// Joining a new room; the server assigns its id.
  case create(spaceID: Int64)
  case join(spaceID: Int64, roomID: Int64)
  /// Moving the user's call to this device, or resuming it here.
  case move(spaceID: Int64, roomID: Int64)
  case leave(spaceID: Int64)
}
