import Foundation
import InlineConfig

extension UserDefaults {
  #if os(macOS)
  static func sharedSuiteName(userProfile: String?) -> String {
    let base = "2487AN8AL4.chat.inline"
    if let userProfile {
      return "\(base).\(userProfile)"
    }
    return base
  }

  public static var shared: UserDefaults {
    let suiteName = sharedSuiteName(userProfile: ProjectConfig.userProfile)
    return UserDefaults(suiteName: suiteName)!
  }

  #elseif os(iOS)
  public static var shared: UserDefaults {
    UserDefaults(suiteName: "group.chat.inline")!
  }

  #endif
}
