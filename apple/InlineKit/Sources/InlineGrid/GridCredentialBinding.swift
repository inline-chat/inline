import InlineProtocol

/// New credentials bind to the stable call and rotating owner. Legacy
/// compatibility is limited to an explicit macOS admission while capability is
/// OFF, with the existing user/membership participant identity still exact.
enum GridCredentialBinding {
  static func accepts(
    credentials: GridConnectionCredentials,
    target: GridMediaTarget,
    userID: Int64,
    callTransferEnabled: Bool
  ) -> Bool {
    guard credentials.hasConnection,
          credentials.connection.roomID == target.roomID,
          credentials.connection.generation == target.generation,
          !target.membershipID.isEmpty,
          credentials.participantIdentity == "inline-grid-user-\(userID)-\(target.membershipID)"
    else { return false }
    if callTransferEnabled {
      return !target.callID.isEmpty && credentials.callID == target.callID
        && credentials.membershipID == target.membershipID
    }
    return (credentials.callID.isEmpty || credentials.callID == target.callID)
      && (credentials.membershipID.isEmpty || credentials.membershipID == target.membershipID)
  }
}
