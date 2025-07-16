import Foundation

/// Represents a language for translation
public struct Language: Identifiable, Hashable, Sendable {
  public let id = UUID()
  public let name: String
  public let code: String
  public let nativeName: String
  public let flag: String

  public init(name: String, code: String, nativeName: String, flag: String) {
    self.name = name
    self.code = code
    self.nativeName = nativeName
    self.flag = flag
  }
}

public extension Language {
  /// Get the current user's preferred language, or fall back to system language
  static func getCurrentLanguage() -> Language {
    let currentCode = UserLocale.getCurrentLanguage()
    return allLanguages.first { $0.code == currentCode } ?? .english
  }

  /// All supported languages for translation
  static let allLanguages: [Language] = [
    .english,
    .chineseTraditional,
    .chineseSimplified,
    .spanish,
    .french,
    .persian,
    .japanese,
    .tagalog,
  ]

  /// Languages for picker display, with prioritized languages first
  static func getLanguagesForPicker() -> [Language] {
    allLanguages
  }
}

public extension Language {
  static let english = Language(
    name: "English",
    code: "en",
    nativeName: "English",
    flag: "🇺🇸"
  )

  static let spanish = Language(
    name: "Spanish",
    code: "es",
    nativeName: "Español",
    flag: "🇪🇸"
  )

  static let french = Language(
    name: "French",
    code: "fr",
    nativeName: "Français",
    flag: "🇫🇷"
  )

  static let japanese = Language(
    name: "Japanese",
    code: "ja",
    nativeName: "日本語",
    flag: "🇯🇵"
  )

  static let chineseSimplified = Language(
    name: "Chinese (Simplified)",
    code: "zh-Hans",
    nativeName: "简体中文",
    flag: "🇨🇳"
  )

  static let chineseTraditional = Language(
    name: "Chinese (Traditional)",
    code: "zh-Hant",
    nativeName: "繁體中文",
    flag: "🇹🇼"
  )

  static let tagalog = Language(
    name: "Tagalog",
    code: "tl",
    nativeName: "Tagalog",
    flag: "🇵🇭"
  )

  static let persian = Language(
    name: "Persian",
    code: "fa",
    nativeName: "فارسی",
    flag: "🇮🇷"
  )
}
