import Foundation
import NaturalLanguage

actor LanguageDetector {
  private static let supportedLanguages: [NLLanguage] = [
    .traditionalChinese,
    .simplifiedChinese,
    .english,
    .persian,
  ]

  /// Detects the language of a given text
  /// - Parameter text: The text to detect the language of
  /// - Returns: The language code of the text
  static func simpleDetect(_ text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.reset()
    recognizer.processString(text)
    guard let languageCode = recognizer.dominantLanguage?.rawValue else {
      return nil
    }
    return languageCode
  }

  public static func cleanText(_ text: String) -> String {
    // Remove URLs
    let urlPattern = "https?://\\S+"
    let withoutUrls = text.replacingOccurrences(of: urlPattern, with: "", options: .regularExpression)

    // Remove @mentions
    let mentionPattern = "@\\S+"
    let withoutMentions = withoutUrls.replacingOccurrences(of: mentionPattern, with: "", options: .regularExpression)

    // remove emojis
    let withoutEmojis = withoutMentions.replacingOccurrences(of: "[\\p{Emoji}]", with: "", options: .regularExpression)

    return withoutEmojis.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Detects the top 2 dominant languages from supported languages
  /// - Parameter text: The text to detect languages from
  /// - Returns: Array of up to 2 language codes, ordered by confidence
  static func advancedDetect(_ rawText: String) -> [String] {
    // clean text
    let text = Self.cleanText(rawText)

    // setup
    let recognizer = NLLanguageRecognizer()
    let confidenceThreshold = 0.4
    let minimumSegmentLength = 2
    // Common scripts we want to group with surrounding text
    let commonScripts: Set<String> = ["Common", "Inherited"]

    // process
    // recognizer.processString(text)

    /// Detects languages in mixed text using direct Unicode script detection
    var results: Set<String> = []

    // Pre-allocate buffers for better performance
    var currentScriptBuffer = String()
    currentScriptBuffer.reserveCapacity(64) // Reasonable starting capacity
    var currentScript: String?

    // Scan through text scalar-by-scalar for script changes
    for scalar in text.unicodeScalars {
      // Get the script name using Character properties
      let scriptName = getUnicodeScriptName(for: scalar)

      // Common script (punctuation, spaces) gets added to the current segment
      if commonScripts.contains(scriptName) {
        currentScriptBuffer.unicodeScalars.append(scalar)
        continue
      }

      // Handle script change
      if scriptName != currentScript {
        // Process previous segment if it exists
        if !currentScriptBuffer.isEmpty, currentScript != nil,
           !commonScripts.contains(currentScript!)
        {
          if let language = Self.detectLanguageForSegment(recognizer, currentScriptBuffer) {
            results.insert(language.rawValue)
          }
          currentScriptBuffer.removeAll(keepingCapacity: true)
        }
        currentScript = scriptName
      }

      // Add to current segment
      currentScriptBuffer.unicodeScalars.append(scalar)
    }

    // Process the final segment
    if !currentScriptBuffer.isEmpty, currentScript != nil,
       !commonScripts.contains(currentScript!)
    {
      if let language = Self.detectLanguageForSegment(recognizer, currentScriptBuffer) {
        results.insert(language.rawValue)
      }
    }

    return results.map { $0 }
  }

  /// Get the Unicode script name for a scalar
  private static func getUnicodeScriptName(for scalar: UnicodeScalar) -> String {
    // Method 1: Using CFStringTransform for script detection
    let char = String(scalar)
    let cfStr = char as CFString
    var scriptCode: CFStringEncoding = CFStringGetSmallestEncoding(cfStr)

    if let scriptName = CFStringGetNameOfEncoding(scriptCode) as String? {
      // Simplify to basic script category
      if scriptName.contains("Latin") { return "Latin" }
      if scriptName.contains("Han") || scriptName.contains("Chinese") { return "Han" }
      if scriptName.contains("Cyrillic") { return "Cyrillic" }
      if scriptName.contains("Arabic") { return "Arabic" }
      // Add more script mappings as needed

      return scriptName
    }

    // Method 2: Simple range checks for common scripts as fallback
    let value = scalar.value
    if (0x0000 ... 0x007F).contains(value) { return "Latin" } // Basic Latin
    if (0x0080 ... 0x024F).contains(value) { return "Latin" } // Extended Latin
    if (0x0400 ... 0x04FF).contains(value) { return "Cyrillic" } // Cyrillic
    if (0x0600 ... 0x06FF).contains(value) { return "Arabic" } // Arabic
    if (0x3040 ... 0x309F).contains(value) { return "Hiragana" } // Hiragana
    if (0x30A0 ... 0x30FF).contains(value) { return "Katakana" } // Katakana
    if (0x4E00 ... 0x9FFF).contains(value) { return "Han" } // CJK Unified Ideographs

    // Default fallback
    return "Common"
  }

  private static func detectLanguageForSegment(_ recognizer: NLLanguageRecognizer, _ text: String) -> NLLanguage? {
    // Skip short segments for better performance and accuracy
    guard text.count >= 2 else { return nil }

    recognizer.reset()
    recognizer.languageConstraints = supportedLanguages
    recognizer.languageHints = [
      .english: 0.8,
      .traditionalChinese: 0.5,
    ]
    recognizer.processString(text)

    let language = recognizer.dominantLanguage
    var confidence: Double = 0

    if let lang = language {
      let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
      confidence = hypotheses[lang] ?? 0
    }

    // Only return languages with sufficient confidence
    return confidence >= 0.5 ? language : nil
  }
}
