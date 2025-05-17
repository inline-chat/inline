import Combine
import Logger
import NaturalLanguage

@MainActor
public final class TranslationAlertDismiss {
  public static let shared = TranslationAlertDismiss()

  private let userDefaults = UserDefaults.standard
  private let dismissedKeyPrefix = "translation_alert_dismissed_"
  private let log = Log.scoped("TranslationAlertDismiss")

  private init() {}

  /// Store the dismissed state for a specific peer
  public func dismissForPeer(_ peer: Peer) {
    let key = dismissedKeyPrefix + peer.toString()
    userDefaults.set(true, forKey: key)
    log.debug("Dismissed translation alert for peer: \(peer.toString())")
  }

  /// Check if translation alert is dismissed for a specific peer
  public func isDismissedForPeer(_ peer: Peer) -> Bool {
    let key = dismissedKeyPrefix + peer.toString()
    return userDefaults.bool(forKey: key)
  }

  /// Reset dismiss states for all peers
  public func resetAllDismissStates() {
    // Get all keys that start with our prefix
    let allKeys = userDefaults.dictionaryRepresentation().keys
    let dismissKeys = allKeys.filter { $0.hasPrefix(dismissedKeyPrefix) }

    // Remove all dismiss state keys
    for key in dismissKeys {
      userDefaults.removeObject(forKey: key)
    }

    log.debug("Reset all translation alert dismiss states")
  }
}
