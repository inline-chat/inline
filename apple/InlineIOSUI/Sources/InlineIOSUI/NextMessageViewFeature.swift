import Foundation

public enum MessageViewImplementation: Equatable, Sendable {
  case legacy
  case next
}

public enum NextMessageViewFeature {
  public static let preferenceKey = "experimental.iosNextMessageView"

  /// The next view is the default. Builds that show debug tools can turn it off to compare.
  public static func selectedImplementation(
    defaults: UserDefaults = .standard,
    allowsOverride: Bool = true
  ) -> MessageViewImplementation {
    guard allowsOverride, defaults.object(forKey: preferenceKey) as? Bool == false else { return .next }
    return .legacy
  }
}
