import Foundation
import Logger

public class UserLocale {
  private static let log = Log.scoped("UserLocale", enableTracing: false)
  private static let preferredTranslationLanguageKey = "preferred_translation_language"
  
  // In-memory cache for preferred translation language
  private static let cacheLock = NSLock()
  nonisolated(unsafe) private static var cachedPreferredLanguage: String?
  nonisolated(unsafe) private static var cacheLoaded = false

  public static func getCurrentLocale() -> String {
    Locale.current.identifier
  }

  public static func getCurrentLanguage() -> String {
    // Check if user has set a custom translation language preference
    if let customLanguage = getPreferredTranslationLanguage() {
      return customLanguage
    }
    
    // Fallback to system language
    return getPreferredLanguage()
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
  
  // MARK: - Custom Translation Language Preference
  
  /// Get the user's preferred translation language if set
  public static func getPreferredTranslationLanguage() -> String? {
    return cacheLock.withLock {
      // Return cached value if available
      if cacheLoaded {
        return cachedPreferredLanguage
      }
      
      // Load from UserDefaults on first access
      let stored = UserDefaults.standard.string(forKey: preferredTranslationLanguageKey)
      cachedPreferredLanguage = stored
      cacheLoaded = true
      
      log.debug("Retrieved preferred translation language: \(stored ?? "nil")")
      return stored
    }
  }
  
  /// Set the user's preferred translation language
  public static func setPreferredTranslationLanguage(_ languageCode: String?) {
    log.debug("Setting preferred translation language to: \(languageCode ?? "nil")")
    
    cacheLock.withLock {
      // Update cache
      cachedPreferredLanguage = languageCode
      cacheLoaded = true
    }
    
    // Update UserDefaults
    if let languageCode = languageCode {
      UserDefaults.standard.set(languageCode, forKey: preferredTranslationLanguageKey)
    } else {
      UserDefaults.standard.removeObject(forKey: preferredTranslationLanguageKey)
    }
  }
  
  /// Get the system language (without custom preference override)
  public static func getSystemLanguage() -> String {
    return getPreferredLanguage()
  }
}
