import Foundation

public enum InAppLinkPreferences {
  public static let openLinksInAppKey = "ios.openLinksInApp"
  public static let defaultOpenLinksInApp = true

  public static func opensLinksInApp(userDefaults: UserDefaults = .standard) -> Bool {
    guard let value = userDefaults.object(forKey: openLinksInAppKey) as? Bool else {
      return defaultOpenLinksInApp
    }
    return value
  }

  public static func setOpensLinksInApp(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
    userDefaults.set(enabled, forKey: openLinksInAppKey)
  }
}
