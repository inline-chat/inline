import Foundation
import Auth

public extension Notification.Name {
  static let realtimeV2ConnectionInitFailed = Notification.Name("realtimeV2ConnectionInitFailed")
  static let realtimeV2AuthInvalidated = Notification.Name("realtimeV2AuthInvalidated")
}

enum RealtimeAuthInvalidationNotification {
  /// The same immutable receipt must survive both the event queue and the notification queue.
  /// The platform receiver still has to admit logout atomically using this receipt.
  @discardableResult
  static func post(
    _ receipt: AuthInvalidationReceipt,
    auth: AuthHandle,
    center: NotificationCenter = .default
  ) -> Bool {
    guard auth.isCurrent(receipt) else { return false }
    center.post(name: .realtimeV2AuthInvalidated, object: receipt)
    return true
  }
}
