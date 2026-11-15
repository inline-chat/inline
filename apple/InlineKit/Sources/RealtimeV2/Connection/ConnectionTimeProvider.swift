import Foundation

public protocol ConnectionTimeProvider: Sendable {
  func now() -> Date
  func sleep(for duration: Duration) async
  /// Monotonic seconds, used to tell a late timer (a frozen process) from a dead socket.
  func uptime() -> TimeInterval
}

public extension ConnectionTimeProvider {
  func uptime() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }
}

public struct SystemConnectionTimeProvider: ConnectionTimeProvider {
  private let clock = ContinuousClock()

  public init() {}

  public func now() -> Date {
    Date()
  }

  public func sleep(for duration: Duration) async {
    try? await clock.sleep(for: duration)
  }
}
