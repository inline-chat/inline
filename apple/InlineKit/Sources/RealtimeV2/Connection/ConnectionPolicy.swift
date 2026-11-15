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
  /// How long the manager may stay connecting, authenticating or in backoff before it reports
  /// the episode once and rechecks that a deadline is pending. Repeats at this interval.
  public var stuckEpisodeReportDelay: Duration
  /// A connection must stay open this long before the reconnect attempt count resets. A socket
  /// that opens and drops right away keeps escalating its backoff instead of retrying at the
  /// shortest delay forever.
  public var stableOpenDuration: Duration
  /// A heartbeat timeout that fires this much later than scheduled means the process (not the
  /// network) was frozen. The heartbeat gets one more full timeout instead of a teardown.
  public var pingTimerLagTolerance: Duration
  /// How many times one heartbeat may be extended because the process was frozen or the account
  /// pipeline was still applying server traffic when its pong was due.
  public var maxPingTimeoutGraces: Int

  public init(
    backoff: BackoffPolicy = .default,
    authTimeout: Duration = .seconds(10),
    connectTimeout: Duration = .seconds(10),
    pingInterval: Duration = .seconds(5),
    pingTimeoutGood: Duration = .seconds(6),
    pingTimeoutConstrained: Duration = .seconds(12),
    backgroundGrace: Duration = .seconds(20),
    wakeProbeTimeout: Duration = .seconds(2),
    stalledCommandReportDelay: Duration = .seconds(20),
    stuckEpisodeReportDelay: Duration = .seconds(60),
    stableOpenDuration: Duration = .seconds(20),
    pingTimerLagTolerance: Duration = .seconds(2),
    maxPingTimeoutGraces: Int = 3
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
    self.stuckEpisodeReportDelay = stuckEpisodeReportDelay
    self.stableOpenDuration = stableOpenDuration
    self.pingTimerLagTolerance = pingTimerLagTolerance
    self.maxPingTimeoutGraces = max(0, maxPingTimeoutGraces)
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
