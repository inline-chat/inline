import Foundation

public class UserLocale {
  public static func getCurrentLocale() -> String {
    Locale.current.identifier
  }

  public static func getCurrentLanguage() -> String {
    Locale.current.language.languageCode?.identifier ?? "en"
  }

  public static func getCurrentRegion() -> String {
    Locale.current.region?.identifier ?? "US"
  }

  public static func getCurrentLocaleInfo() -> (language: String, region: String) {
    let language = getCurrentLanguage()
    let region = getCurrentRegion()
    return (language, region)
  }
}
