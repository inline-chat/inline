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
  case systemWake
  case wakeProbeCompleted(sessionID: UInt64, isHealthy: Bool)

  case transportConnecting(sessionID: UInt64)
  case transportConnected(sessionID: UInt64)
  case transportDisconnected(sessionID: UInt64, errorDescription: String?)

  case protocolOpen(sessionID: UInt64)
  case protocolAuthFailed
  case connectTimeout

  case pingTimeout
  case backoffFired
  case backgroundGraceExpired
}

extension ConnectionEvent {
  var diagnosticName: String {
    switch self {
    case .start: "start"
    case .stop: "stop"
    case .connectNow: "connectNow"
    case .authAvailable: "authAvailable"
    case .authLost: "authLost"
    case .networkAvailable: "networkAvailable"
    case .networkUnavailable: "networkUnavailable"
    case .appForeground: "appForeground"
    case .appBackground: "appBackground"
    case .systemWake: "systemWake"
    case .wakeProbeCompleted: "wakeProbeCompleted"
    case .transportConnecting: "transportConnecting"
    case .transportConnected: "transportConnected"
    case .transportDisconnected: "transportDisconnected"
    case .protocolOpen: "protocolOpen"
    case .protocolAuthFailed: "protocolAuthFailed"
    case .connectTimeout: "connectTimeout"
    case .pingTimeout: "pingTimeout"
    case .backoffFired: "backoffFired"
    case .backgroundGraceExpired: "backgroundGraceExpired"
    }
  }
}
