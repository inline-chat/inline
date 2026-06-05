import Foundation
import NaturalLanguage

actor LanguageDetector {
  private static let supportedLanguages: [NLLanguage] = [
    .traditionalChinese,
    .simplifiedChinese,
    .english,
    .spanish,
    .french,
    .japanese,
    .persian,
  ]

  private static let linkTLDs = [
    "com", "net", "org", "edu", "gov", "io", "ai", "app", "dev", "chat",
    "co", "me", "us", "uk", "ca", "de", "fr", "es", "it", "nl", "se",
    "no", "fi", "dk", "jp", "kr", "cn", "tw", "hk", "sg", "in", "ir",
    "ru", "br", "au", "nz", "xyz", "shop", "site", "online", "cloud",
    "tech", "live", "news", "blog", "page", "store", "to", "ly", "fm", "tv",
  ]

  private static let emailRegex = makeRegex(
    pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,24}\b"#,
    options: [.caseInsensitive]
  )

  private static let linkRegex: NSRegularExpression = {
    let tlds = linkTLDs.joined(separator: "|")
    let hostLabel = #"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
    let terminators = #"\s<>()\[\]{}"'"#
    let fullURL = #"https?://[^\#(terminators)]+"#
    let wwwURL = #"www\.[^\#(terminators)]+"#
    let bareDomainPrefix = #"(?<![@\w-])(?:\#(hostLabel)\.)+(?:\#(tlds))\b"#
    let bareDomainPath = #"(?:[/:?#][^\#(terminators)]*)?"#
    let bareDomain = "\(bareDomainPrefix)\(bareDomainPath)"
    return makeRegex(
      pattern: "\(fullURL)|\(wwwURL)|\(bareDomain)",
      options: [.caseInsensitive]
    )
  }()

  private static let mentionRegex = makeRegex(pattern: #"@\S+"#)
  private static let emojiRegex = makeRegex(pattern: #"[\p{Emoji}]"#)
  private static let whitespaceRegex = makeRegex(pattern: #"\s+"#)

  // Define major script groups
  private static let latinScripts: Set<String> = ["Latin"]
  private static let arabicScripts: Set<String> = ["Arabic"]
  private static let cjkScripts: Set<String> = ["Han", "Hiragana", "Katakana"]
  private static let commonScripts: Set<String> = ["Common", "Inherited"]

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
    let withoutEmails = replacingMatches(of: emailRegex, in: text)
    let withoutLinks = replacingMatches(of: linkRegex, in: withoutEmails)
    let withoutMentions = replacingMatches(of: mentionRegex, in: withoutLinks)
    let withoutEmojis = replacingMatches(of: emojiRegex, in: withoutMentions)
    return replacingMatches(of: whitespaceRegex, in: withoutEmojis).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Detects the top 2 dominant languages from supported languages
  /// - Parameter text: The text to detect languages from
  /// - Returns: Array of up to 2 language codes, ordered by confidence
  static func advancedDetect(_ rawText: String) -> [String] {
    // clean text
    let text = Self.cleanText(rawText)

    // First, collect all segments
    let segments = collectSegments(from: text)

    // Then analyze each segment
    return analyzeSegments(segments)
  }

  private static func collectSegments(from text: String) -> [(scriptGroup: String, text: String)] {
    var segments: [(scriptGroup: String, text: String)] = []
    var currentSegment = ""
    var currentScriptGroup: String?

    // Process each character
    for char in text {
      let scriptName = getUnicodeScriptName(for: char.unicodeScalars.first!)
      let scriptGroup = getScriptGroup(for: scriptName)

      // Skip whitespace
      if char.isWhitespace {
        if !currentSegment.isEmpty {
          segments.append((scriptGroup: currentScriptGroup!, text: currentSegment))
          currentSegment = ""
          currentScriptGroup = nil
        }
        continue
      }

      // Handle script change
      if scriptGroup != currentScriptGroup {
        // Save current segment if it exists
        if !currentSegment.isEmpty {
          segments.append((scriptGroup: currentScriptGroup!, text: currentSegment))
          currentSegment = ""
        }
        currentScriptGroup = scriptGroup
      }

      // Add character to current segment
      currentSegment.append(char)
    }

    // Add final segment if exists
    if !currentSegment.isEmpty {
      segments.append((scriptGroup: currentScriptGroup!, text: currentSegment))
    }

    // Merge adjacent segments of the same script group
    var mergedSegments: [(scriptGroup: String, text: String)] = []
    for segment in segments {
      if let lastSegment = mergedSegments.last, lastSegment.scriptGroup == segment.scriptGroup {
        mergedSegments[mergedSegments.count - 1].text += " " + segment.text
      } else {
        mergedSegments.append(segment)
      }
    }

    return mergedSegments
  }

  private static func analyzeSegments(_ segments: [(scriptGroup: String, text: String)]) -> [String] {
    let recognizer = NLLanguageRecognizer()
    var results: Set<String> = []

    for segment in segments {
      if let language = detectLanguageForSegment(recognizer, segment.text) {
        results.insert(language.rawValue)
      }
    }

    return Array(results)
  }

  private static func getScriptGroup(for scriptName: String) -> String {
    if latinScripts.contains(scriptName) {
      return "Latin"
    } else if arabicScripts.contains(scriptName) {
      return "Arabic"
    } else if cjkScripts.contains(scriptName) {
      return "CJK"
    } else if commonScripts.contains(scriptName) {
      return "Common"
    }
    return scriptName
  }

  /// Get the Unicode script name for a scalar
  private static func getUnicodeScriptName(for scalar: UnicodeScalar) -> String {
    // Method 1: Using CFStringTransform for script detection
    let char = String(scalar)
    let cfStr = char as CFString
    let scriptCode: CFStringEncoding = CFStringGetSmallestEncoding(cfStr)

    if let scriptName = CFStringGetNameOfEncoding(scriptCode) as String? {
      return scriptName
    }
    return ""
  }

  private static func detectLanguageForSegment(_ recognizer: NLLanguageRecognizer, _ text: String) -> NLLanguage? {
    recognizer.reset()
    // recognizer.languageConstraints = Self.supportedLanguages

    // FIXME: improve language detection
    recognizer.languageHints = [
      .english: 0.9,
      .traditionalChinese: 0.9,
      // others
      .persian: 0.5,
      .simplifiedChinese: 0.5,
      .spanish: 0.5,
      .french: 0.5,
      .japanese: 0.5,
      .arabic: 0.5,
    ]
    recognizer.processString(text)

    let language = recognizer.dominantLanguage
    var confidence: Double = 0

    if let lang = language {
      let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
      confidence = hypotheses[lang] ?? 0
    }

    // Only return languages with sufficient confidence
    return confidence >= 0.1 ? language : nil
  }

  private static func replacingMatches(of regex: NSRegularExpression, in text: String) -> String {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
  }

  private static func makeRegex(
    pattern: String,
    options: NSRegularExpression.Options = []
  ) -> NSRegularExpression {
    do {
      return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
      preconditionFailure("Invalid language detector regex: \(error)")
    }
  }
}
