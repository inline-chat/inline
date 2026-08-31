import Foundation
import UserNotifications

/// A request-local completion gate. Expiry must not wait for the main queue.
public final class InlineNotificationDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var fallback: UNNotificationContent
  private var handler: ((UNNotificationContent) -> Void)?
  private var cancellations: [@Sendable () -> Void] = []

  public init(content: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
    fallback = content.copy() as! UNNotificationContent
    self.handler = handler
  }

  public var isPending: Bool { lock.withLock { handler != nil } }

  @discardableResult
  public func updateFallback(_ content: UNNotificationContent) -> Bool {
    let snapshot = content.copy() as! UNNotificationContent
    return lock.withLock {
      guard handler != nil else { return false }
      fallback = snapshot
      return true
    }
  }

  public func cancelOnFinish(_ cancel: @escaping @Sendable () -> Void) {
    let alreadyFinished = lock.withLock {
      guard handler != nil else { return true }
      cancellations.append(cancel)
      return false
    }
    if alreadyFinished { cancel() }
  }

  public func finish(with content: UNNotificationContent? = nil) {
    let completion = lock.withLock { () -> (() -> Void)? in
      guard let handler else { return nil }
      self.handler = nil
      let result = content ?? fallback
      let cancellations = self.cancellations
      self.cancellations = []
      return {
        cancellations.forEach { $0() }
        handler(result)
      }
    }
    // Neither client callbacks nor task cancellation may run while holding the lock.
    completion?()
  }
}
