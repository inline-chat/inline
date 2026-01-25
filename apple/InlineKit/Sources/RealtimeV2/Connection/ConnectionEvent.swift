public enum ConnectionEvent: Sendable {
  case start
  case stop
  case connectNow

  case authAvailable
  case authLost

  case networkAvailable
  case networkUnavailable

  case appForeground
  case appBackground

  case transportConnecting
  case transportConnected
  case transportDisconnected(errorDescription: String?)

  case protocolOpen
  case protocolAuthFailed

  case pingTimeout
  case backoffFired
  case backgroundGraceExpired
}
