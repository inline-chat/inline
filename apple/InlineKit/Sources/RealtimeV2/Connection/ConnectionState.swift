public enum ConnectionState: Sendable {
  case stopped
  case waitingForConstraints
  case connectingTransport
  case authenticating
  case open
  case backoff
  case backgroundSuspended
}

public extension ConnectionState {
  var isActive: Bool {
    switch self {
    case .connectingTransport, .authenticating, .open, .backoff:
      true
    case .stopped, .waitingForConstraints, .backgroundSuspended:
      false
    }
  }
}
