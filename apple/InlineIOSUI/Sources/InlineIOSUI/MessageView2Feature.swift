import Foundation

public enum MessageViewImplementation: Equatable, Sendable {
  case legacy
  case v2
}

public enum MessageView2Feature {
  public static let preferenceKey = "experimental.iosNextMessageView"

  public static func selectedImplementation(
    defaults: UserDefaults = .standard,
    isExperimentAvailable: Bool = true
  ) -> MessageViewImplementation {
    isExperimentAvailable && defaults.bool(forKey: preferenceKey) ? .v2 : .legacy
  }
}
