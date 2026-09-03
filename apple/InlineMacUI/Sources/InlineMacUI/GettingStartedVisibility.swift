import Foundation

public enum GettingStartedVisibility {
  public static let dismissalPreferenceKey = "gettingStarted.isDismissed"

  public static func shouldShow(
    defaults: UserDefaults = .standard
  ) -> Bool {
    !defaults.bool(forKey: dismissalPreferenceKey)
  }
}
