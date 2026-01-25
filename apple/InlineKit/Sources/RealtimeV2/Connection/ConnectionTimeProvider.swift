import Foundation

public protocol ConnectionTimeProvider: Sendable {
  func now() -> Date
  func sleep(for duration: Duration) async
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
