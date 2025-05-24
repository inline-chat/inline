import Foundation

extension UserDefaults {
  #if os(macOS)
  public static var shared: UserDefaults {
    UserDefaults(suiteName: "2487AN8AL4.chat.inline")!
  }

  #elseif os(iOS)
  public static var shared: UserDefaults {
    UserDefaults(suiteName: "group.chat.inline")!
  }

  #endif
}
