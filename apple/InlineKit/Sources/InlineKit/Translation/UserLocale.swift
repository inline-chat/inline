import Foundation
import Logger

public class UserLocale {
  private static let log = Log.scoped("UserLocale", enableTracing: false)

  public static func getCurrentLocale() -> String {
    Locale.current.identifier
  }

  public static func getCurrentLanguage() -> String {
    // Locale.current.language.languageCode?.identifier ?? "en"
    getPreferredLanguage()
  }

  public static func getCurrentRegion() -> String {
    Locale.current.region?.identifier ?? "US"
  }

  public static func getPreferredLanguage() -> String {
    do {
      let preferredLocale = Locale(identifier: Locale.preferredLanguages.first ?? "en")

      // Get the language code
      let languageCode = preferredLocale.language.languageCode?.identifier ?? "en"

      // For most languages, just return the language code
      if languageCode != "zh" {
        return languageCode
      }

      // For Chinese, include the script code
      if let scriptCode = preferredLocale.language.script?.identifier {
        return "\(languageCode)-\(scriptCode)"
      }

      // Fallback for Chinese without script code
      return "zh-Hant" // Default to Simplified Chinese
    } catch {
      // Handle error if needed
      log.error("Error getting preferred language: \(error)")

      // Fallback
      return Locale.current.language.languageCode?.identifier ?? "en"
    }
  }

  public static func getCurrentLocaleInfo() -> (language: String, region: String) {
    let language = getCurrentLanguage()
    let region = getCurrentRegion()
    return (language, region)
  }
}
