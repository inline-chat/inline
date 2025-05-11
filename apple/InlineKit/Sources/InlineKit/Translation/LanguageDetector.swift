import NaturalLanguage

class LanguageDetector {
  private static let supportedLanguages: [NLLanguage] = [
    .traditionalChinese,
    .simplifiedChinese,
    .english,
    .persian,
  ]

  /// Detects the language of a given text
  /// - Parameter text: The text to detect the language of
  /// - Returns: The language code of the text
  static func detect(_ text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)

    guard let languageCode = recognizer.dominantLanguage?.rawValue else {
      return nil
    }

    // let locale = Locale(identifier: languageCode)
    // ???

    return languageCode
  }

  public static func cleanText(_ text: String) -> String {
    // Remove URLs
    let urlPattern = "https?://\\S+"
    let withoutUrls = text.replacingOccurrences(of: urlPattern, with: "", options: .regularExpression)

    // Remove @mentions
    let mentionPattern = "@\\S+"
    let withoutMentions = withoutUrls.replacingOccurrences(of: mentionPattern, with: "", options: .regularExpression)

    return withoutMentions.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Detects the top 2 dominant languages from supported languages
  /// - Parameter text: The text to detect languages from
  /// - Returns: Array of up to 2 language codes, ordered by confidence
  static func detectTopTwoSupported(_ text: String) -> [String] {
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = supportedLanguages
    recognizer.languageHints = [
      .english: 0.8,
      .traditionalChinese: 0.5,
    ]
    let cleanedText = cleanText(text)
    recognizer.processString(cleanedText)

    // Get language hypotheses for supported languages
    let hypotheses = recognizer.languageHypotheses(withMaximum: 2)

    // Filter and sort by confidence
    return hypotheses
//      .filter { supportedLanguages.contains($0.key) }
//      .sorted { $0.value > $1.value }
      // .prefix(2)
      .map(\.key.rawValue)
  }
}
