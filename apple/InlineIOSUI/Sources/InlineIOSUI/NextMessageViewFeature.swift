import Foundation

public enum MessageViewImplementation: Equatable, Sendable {
  case legacy
  case next
}

public enum NextMessageViewFeature {
  public static let preferenceKey = "experimental.iosNextMessageView"

  public static func selectedImplementation(
    defaults: UserDefaults = .standard,
    isExperimentAvailable: Bool = true
  ) -> MessageViewImplementation {
    isExperimentAvailable && defaults.bool(forKey: preferenceKey) ? .next : .legacy
  }
}
