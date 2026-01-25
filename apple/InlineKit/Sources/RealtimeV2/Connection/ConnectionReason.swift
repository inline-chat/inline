public enum ConnectionReason: Sendable, Equatable {
  case none
  case userStop
  case authLost
  case authFailed
  case authTimeout
  case transportError
  case transportDisconnected
  case pingTimeout
  case networkUnavailable
  case backgroundSuspended
  case constraintUnavailable
}
