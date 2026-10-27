import Foundation
import Logger
import Synchronization

/// One connection state change in fixed program vocabulary.
struct ConnectionTransitionRecord: Sendable, Equatable {
  let state: ConnectionState
  let reason: ConnectionReason
  let attempt: UInt32
  let session: UInt64
  /// Present when this transition reopened a connection that had been open before.
  let recovery: ConnectionRecovery?
}

/// How a dropped connection came back.
struct ConnectionRecovery: Sendable, Equatable {
  /// From leaving open to opening again, including time without network or in the background.
  let downMilliseconds: Int
  /// From the first attempt of the final reconnect run to open. Waiting for network, foreground
  /// or credentials is not reconnect latency.
  let reconnectMilliseconds: Int
  let dropReason: ConnectionReason
  let attempts: UInt32
  let protocolName: String?
}

/// Where connection telemetry goes. Production projects each record into a privacy-safe Sentry
/// breadcrumb plus one structured health event per recovery; tests capture records directly.
struct ConnectionTelemetry: Sendable {
  let record: @Sendable (ConnectionTransitionRecord) -> Void

  static let sentry = ConnectionTelemetry { record in
    var data: [String: Any] = [
      "state": record.state.telemetryName,
      "reason": record.reason.telemetryName,
      "attempt": Int(record.attempt),
      "session": Int(truncatingIfNeeded: record.session),
    ]
    if let recovery = record.recovery {
      var health: [String: Any] = [
        "down_ms": recovery.downMilliseconds,
        "reconnect_ms": recovery.reconnectMilliseconds,
        "drop_reason": recovery.dropReason.telemetryName,
        "attempts": Int(recovery.attempts),
      ]
      if let protocolName = recovery.protocolName { health["protocol"] = protocolName }
      data.merge(health) { current, _ in current }
      PerformanceTrace.healthEvent("realtime.connection.recovered", data: health)
    }
    PerformanceTrace.breadcrumb(
      "realtime connection state",
      category: "realtime.connection",
      level: record.state == .backoff ? .warning : .info,
      data: data
    )
  }
}

/// The protocol carrying the current connection. Transport selection records it when a connection
/// authenticates; errors are tagged with it and connection telemetry reads it on open.
public enum RealtimeTelemetryContext {
  private static let current = Mutex<String?>(nil)

  public static var protocolName: String? { current.withLock { $0 } }

  static func recordProtocol(_ name: String) {
    current.withLock { $0 = name }
    PerformanceTrace.setDiagnosticTag("realtime.protocol", value: name)
  }
}

extension ConnectionState {
  var telemetryName: String {
    switch self {
    case .stopped: "stopped"
    case .waitingForConstraints: "waiting_for_constraints"
    case .connectingTransport: "connecting_transport"
    case .authenticating: "authenticating"
    case .open: "open"
    case .backoff: "backoff"
    case .backgroundSuspended: "background_suspended"
    }
  }
}

extension ConnectionReason {
  var telemetryName: String {
    switch self {
    case .none: "none"
    case .userStop: "user_stop"
    case .authLost: "auth_lost"
    case .authFailed: "auth_failed"
    case .authTimeout: "auth_timeout"
    case .transportError: "transport_error"
    case .transportDisconnected: "transport_disconnected"
    case .pingTimeout: "ping_timeout"
    case .networkUnavailable: "network_unavailable"
    case .networkRouteChanged: "network_route_changed"
    case .applicationResumed: "application_resumed"
    case .wakeProbeFailed: "wake_probe_failed"
    case .backgroundSuspended: "background_suspended"
    case .constraintUnavailable: "constraint_unavailable"
    }
  }
}
