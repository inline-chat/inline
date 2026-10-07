import InlineProtocol

/// Validates the committed claim against the latest projections already
/// accepted by this process. A successful RPC alone cannot authorize audio.
enum GridCallClaimAdmission {
  static func accepts(
    committedCall: GridCurrentCall,
    newestGrid: InlineProtocol.Grid?,
    acceptedAuthority: GridOwnedRoomAuthority?
  ) -> Bool {
    guard committedCall.ownedByCurrentSession,
          !committedCall.callID.isEmpty,
          !committedCall.membershipID.isEmpty,
          acceptedAuthority?.matches(committedCall) == true,
          newestGrid?.enabled == true,
          newestGrid?.spaceID == committedCall.spaceID,
          newestGrid?.rooms.first(where: { $0.id == committedCall.roomID })?.avatars.contains(where: {
            $0.ownedByCurrentSession && $0.membershipID == committedCall.membershipID
          }) == true
    else { return false }
    return true
  }
}

/// Only this small self tuple is retained before optimistic UI overlays.
/// It prevents a pending Join's avatar projection from granting media access.
struct GridOwnedRoomAuthority: Equatable, Sendable {
  let spaceID: Int64
  let roomID: Int64
  let membershipID: String

  func matches(_ call: GridCurrentCall) -> Bool {
    spaceID == call.spaceID && roomID == call.roomID && membershipID == call.membershipID
  }
}
