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

  public init(
    backoff: BackoffPolicy = .default,
    authTimeout: Duration = .seconds(10),
    connectTimeout: Duration = .seconds(10),
    pingInterval: Duration = .seconds(10),
    pingTimeoutGood: Duration = .seconds(8),
    pingTimeoutConstrained: Duration = .seconds(20),
    backgroundGrace: Duration = .seconds(30),
    wakeProbeTimeout: Duration = .seconds(2)
  ) {
    self.backoff = backoff
    self.authTimeout = authTimeout
    self.connectTimeout = connectTimeout
    self.pingInterval = pingInterval
    self.pingTimeoutGood = pingTimeoutGood
    self.pingTimeoutConstrained = pingTimeoutConstrained
    self.backgroundGrace = backgroundGrace
    self.wakeProbeTimeout = wakeProbeTimeout
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
