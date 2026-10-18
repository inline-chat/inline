public enum ConnectionReason: Sendable, Equatable, CaseIterable {
  case none
  case userStop
  case authLost
  case authFailed
  case authTimeout
  case transportError
  case transportDisconnected
  case pingTimeout
  case networkUnavailable
  /// The system network route changed while open; the transport was replaced.
  case networkRouteChanged
  /// The app became active without a retained transport; the connection was replaced.
  case applicationResumed
  /// A wake probe found the open transport unresponsive.
  case wakeProbeFailed
  case backgroundSuspended
  case constraintUnavailable
}
