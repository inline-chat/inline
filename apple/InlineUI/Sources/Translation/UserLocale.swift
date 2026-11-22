import Foundation
import Logger
import InlineKit

public class UserLocale {
  private static let log = Log.scoped("UserLocale", level: .info)
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
    regionIdentifier(of: .current) ?? "US"
  }

  public static func getPreferredLanguage() -> String {
    let preferredLocale = Locale(identifier: Locale.preferredLanguages.first ?? "en")

    // Get the language code
    let parts = languageParts(of: preferredLocale)
    let languageCode = parts.language ?? "en"

    // For most languages, just return the language code
    if languageCode != "zh" {
      return languageCode
    }

    // For Chinese, include the script code
    if let scriptCode = parts.script {
      return "\(languageCode)-\(scriptCode)"
    }

    // Fallback for Chinese without script code
    return "zh-Hant" // Default to Simplified Chinese
  }

  // `Locale.Language` and `Locale.region` are iOS 16; iOS 15 reads the same codes from the
  // older per-component properties.
  private static func languageParts(of locale: Locale) -> (language: String?, script: String?) {
    if #available(iOS 16, *) {
      return (locale.language.languageCode?.identifier, locale.language.script?.identifier)
    }
    #if os(iOS)
    return (locale.languageCode, locale.scriptCode)
    #else
    return (nil, nil)
    #endif
  }

  private static func regionIdentifier(of locale: Locale) -> String? {
    if #available(iOS 16, *) {
      return locale.region?.identifier
    }
    #if os(iOS)
    return locale.regionCode
    #else
    return nil
    #endif
  }

  public static func getCurrentLocaleInfo() -> (language: String, region: String) {
    let language = getCurrentLanguage()
    let region = getCurrentRegion()
    return (language, region)
  }
  
  // MARK: - Custom Translation Language Preference
  
  /// Get the user's preferred translation language if set
  public static func getPreferredTranslationLanguage() -> String? {
    // Cached reads and writes share the same lock across UI and translation tasks.
    return cacheLock.withLock {
      if cacheLoaded {
        return cachedPreferredLanguage
      }

      // Load from UserDefaults on first access
      let stored = UserDefaults.standard.string(forKey: preferredTranslationLanguageKey)
      cachedPreferredLanguage = stored
      cacheLoaded = true

      log.trace("Retrieved preferred translation language: \(stored ?? "nil")")
      return stored
    }
  }
  
  /// Set the user's preferred translation language
  public static func setPreferredTranslationLanguage(_ languageCode: String?) {
    log.trace("Setting preferred translation language to: \(languageCode ?? "nil")")
    
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
