import NaturalLanguage

class LanguageDetector {
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
}
