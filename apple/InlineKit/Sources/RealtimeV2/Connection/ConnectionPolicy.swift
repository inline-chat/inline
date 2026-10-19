import Foundation

public struct ConnectionPolicy: Sendable {
  public var backoff: BackoffPolicy
  public var authTimeout: Duration
  public var connectTimeout: Duration
  public var pingInterval: Duration
  public var pingTimeoutGood: Duration
  public var pingTimeoutConstrained: Duration
  public var backgroundGrace: Duration
  public var wakeProbeTimeout: Duration
  /// How long one command may run before the manager reports it as stalled. Every later
  /// command, timer and lifecycle event waits behind it.
  public var stalledCommandReportDelay: Duration

  public init(
    backoff: BackoffPolicy = .default,
    authTimeout: Duration = .seconds(10),
    connectTimeout: Duration = .seconds(10),
    pingInterval: Duration = .seconds(5),
    pingTimeoutGood: Duration = .seconds(6),
    pingTimeoutConstrained: Duration = .seconds(12),
    backgroundGrace: Duration = .seconds(20),
    wakeProbeTimeout: Duration = .seconds(2),
    stalledCommandReportDelay: Duration = .seconds(20)
  ) {
    self.backoff = backoff
    self.authTimeout = authTimeout
    self.connectTimeout = connectTimeout
    self.pingInterval = pingInterval
    self.pingTimeoutGood = pingTimeoutGood
    self.pingTimeoutConstrained = pingTimeoutConstrained
    self.backgroundGrace = backgroundGrace
    self.wakeProbeTimeout = wakeProbeTimeout
    self.stalledCommandReportDelay = stalledCommandReportDelay
  }

  public func pingTimeout(for quality: ConnectionNetworkQuality) -> Duration {
    switch quality {
    case .good:
      return pingTimeoutGood
    case .constrained:
      return pingTimeoutConstrained
    }
  }
}
