import Foundation

public struct BackoffPolicy: Sendable {
  public var delay: @Sendable (_ attempt: UInt32) -> Duration

  public init(delay: @escaping @Sendable (_ attempt: UInt32) -> Duration) {
    self.delay = delay
  }

  public static let `default` = BackoffPolicy { attempt in
    defaultDelay(attempt: attempt, unitRandom: Double.random(in: 0.0 ... 1.0))
  }

  /// Early retries grow from 0.2 s to 8 s with ±25% jitter, so clients that lost the same
  /// server (a deploy, a load balancer drain) do not reconnect in synchronized waves.
  /// From the eighth attempt the delay is 8–13 s.
  static func defaultDelay(attempt: UInt32, unitRandom: Double) -> Duration {
    let unit = min(1.0, max(0.0, unitRandom))
    if attempt >= 8 {
      return .seconds(8.0 + unit * 5.0)
    }
    let base = min(8.0, 0.2 + pow(Double(attempt), 1.5) * 0.4)
    return .seconds(base * (0.75 + unit * 0.5))
  }
}
