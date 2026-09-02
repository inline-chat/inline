public enum ConnectionEvent: Sendable {
  case start
  case stop
  case connectNow
  case userInitiatedOperationStarted
  case userInitiatedOperationFinished

  case authAvailable
  case authLost

  // Retained for source compatibility with the original public event surface.
  // ConnectionManager's adapters use the richer path event below.
  case networkAvailable
  case networkUnavailable
  case networkPathChanged(isAvailable: Bool, routeChanged: Bool, quality: ConnectionNetworkQuality)

  // Retained for source compatibility. Platform lifecycle adapters use the
  // explicit retention variants below.
  case appForeground
  case appBackground
  case applicationActive(transportWasRetained: Bool)
  case applicationInactive(keepConnection: Bool)
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
    case .userInitiatedOperationStarted: "userInitiatedOperationStarted"
    case .userInitiatedOperationFinished: "userInitiatedOperationFinished"
    case .authAvailable: "authAvailable"
    case .authLost: "authLost"
    case .networkAvailable: "networkAvailable"
    case .networkUnavailable: "networkUnavailable"
    case .networkPathChanged: "networkPathChanged"
    case .appForeground: "appForeground"
    case .appBackground: "appBackground"
    case .applicationActive: "applicationActive"
    case .applicationInactive: "applicationInactive"
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
