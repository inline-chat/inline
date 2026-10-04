import Foundation

/// One launch-scoped opt-in for presentation and realtime capability negotiation.
/// Restarting applies a settings change consistently to connections and layout caches.
public enum AgentActivityFeature {
  public static let preferenceKey = "experimental.agentActivity"
  public static let isEnabled = isEnabled(in: .standard)

  public static func isEnabled(in defaults: UserDefaults) -> Bool {
    defaults.bool(forKey: preferenceKey)
  }
}
