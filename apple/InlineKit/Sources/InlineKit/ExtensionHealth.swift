import InlineNotificationFence
import Logger
import Sentry

/// Health events from app extensions, relayed through `ExtensionHealthOutbox`.
public enum ExtensionHealth {
  public static func record(_ event: String, _ fields: [String: String] = [:]) {
    ExtensionHealthOutbox.shared.record(event, fields)
  }

  /// Sends what extensions recorded since the last flush, one health event per distinct outcome.
  public static func flush() {
    // Keep the counts for a later flush until Sentry can take them.
    guard SentrySDK.isEnabled else { return }
    for entry in ExtensionHealthOutbox.shared.drain() {
      var data: [String: Any] = entry.fields
      data["count"] = entry.count
      PerformanceTrace.healthEvent(entry.event, data: data)
    }
  }
}
