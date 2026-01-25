import Foundation

public struct BackoffPolicy: Sendable {
  public var delay: @Sendable (_ attempt: UInt32) -> Duration

  public init(delay: @escaping @Sendable (_ attempt: UInt32) -> Duration) {
    self.delay = delay
  }

  public static let `default` = BackoffPolicy { attempt in
    if attempt >= 8 {
      let base = 8.0
      let jitter = Double.random(in: 0.0 ... 5.0)
      return .seconds(base + jitter)
    }

    let computed = min(8.0, 0.2 + pow(Double(attempt), 1.5) * 0.4)
    return .seconds(computed)
  }
}
