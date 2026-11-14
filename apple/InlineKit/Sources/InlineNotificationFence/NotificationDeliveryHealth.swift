import Foundation

/// Fixed vocabulary for the notification extension's health events. Every outcome other than
/// `decrypted` is shown to the user as the generic "New message / Open Inline to read it." alert,
/// so the outcome says which link of the chain failed.
public enum NotificationDeliveryHealth {
  public static let event = "notifications.delivery"
  public static let registrationEvent = "notifications.registration"

  public enum Outcome: String, CaseIterable, Sendable {
    /// Real message text shown.
    case decrypted
    /// The server sent only its generic alert; `placeholder_reason` says why.
    case placeholder
    case unsupportedPayload = "unsupported_payload"
    /// No device key in the keychain (logged out, reinstalled, or never registered).
    case keyMissing = "key_missing"
    /// The keychain could not be read right now.
    case keyUnavailable = "key_unavailable"
    /// Encrypted to a different key than this device holds: an outdated server registration.
    case staleKey = "stale_key"
    case decryptFailed = "decrypt_failed"
    /// The payload's recipient is not the account signed in on this device.
    case withheld
  }

  /// Values the server sends as `placeholderReason` on generic message alerts.
  /// `generic_alert`: a non-message alert to a client registered before encrypted alerts.
  public static let placeholderReasons: Set<String> = [
    "no_device_key", "encryption_failed", "too_large", "generic_alert",
  ]

  public static func placeholderReason(in userInfo: [AnyHashable: Any]) -> String {
    guard let reason = userInfo["placeholderReason"] as? String, placeholderReasons.contains(reason)
    else { return "unknown" }
    return reason
  }
}
