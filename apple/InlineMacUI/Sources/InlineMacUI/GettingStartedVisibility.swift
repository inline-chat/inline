import Foundation

public enum GettingStartedVisibility {
  private static let keyPrefix = "gettingStarted.isVisible"

  public static func preferenceKey(for userID: Int64) -> String {
    "\(keyPrefix).\(userID)"
  }

  /// Records the account's first getting-started decision. A later login must
  /// not hide an undismissed page or resurrect one the user already dismissed.
  public static func prepare(
    for userID: Int64,
    isNewSignup: Bool,
    defaults: UserDefaults = .standard
  ) {
    guard userID > 0 else { return }
    let key = preferenceKey(for: userID)
    guard defaults.object(forKey: key) == nil else { return }
    defaults.set(isNewSignup, forKey: key)
  }

  public static func shouldShow(
    for userID: Int64,
    defaults: UserDefaults = .standard
  ) -> Bool {
    guard userID > 0 else { return false }
    return defaults.bool(forKey: preferenceKey(for: userID))
  }

  public static func dismiss(
    for userID: Int64,
    defaults: UserDefaults = .standard
  ) {
    guard userID > 0 else { return }
    defaults.set(false, forKey: preferenceKey(for: userID))
  }
}
