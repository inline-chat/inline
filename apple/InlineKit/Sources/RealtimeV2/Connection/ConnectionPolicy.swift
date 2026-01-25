import Foundation

public struct ConnectionPolicy: Sendable {
  public var backoff: BackoffPolicy
  public var authTimeout: Duration
  public var connectTimeout: Duration
  public var pingInterval: Duration
  public var pingTimeout: Duration
  public var backgroundGrace: Duration

  public init(
    backoff: BackoffPolicy = .default,
    authTimeout: Duration = .seconds(10),
    connectTimeout: Duration = .seconds(10),
    pingInterval: Duration = .seconds(10),
    pingTimeout: Duration = .seconds(30),
    backgroundGrace: Duration = .seconds(30)
  ) {
    self.backoff = backoff
    self.authTimeout = authTimeout
    self.connectTimeout = connectTimeout
    self.pingInterval = pingInterval
    self.pingTimeout = pingTimeout
    self.backgroundGrace = backgroundGrace
  }
}
