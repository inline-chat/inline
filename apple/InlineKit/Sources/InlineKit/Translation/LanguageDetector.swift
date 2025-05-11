import NaturalLanguage

class LanguageDetector {
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
