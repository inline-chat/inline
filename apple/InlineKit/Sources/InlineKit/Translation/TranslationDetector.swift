import Combine
import Logger
import NaturalLanguage

@MainActor
public final class TranslationDetector {
  public static let shared = TranslationDetector()

  // Minimum confidence threshold for language detection (0.0 to 1.0)
  private let confidenceThreshold: Double = 0.6

  // Supported languages for detection
  private let supportedLanguages: [NLLanguage] = [
    .traditionalChinese,
    .simplifiedChinese,
    .english,
    .persian,
  ]

  private let log = Log.scoped("TranslationDetector")
  private let publisher = PassthroughSubject<Bool, Never>()

  private init() {}

  /// Publisher that emits true when translation is needed, false otherwise
  public var needsTranslation: AnyPublisher<Bool, Never> {
    publisher.eraseToAnyPublisher()
  }

  /// Analyze messages to detect if translation is needed
  /// - Parameter messages: Array of messages to analyze
  public func analyzeMessages(_ messages: [FullMessage]) {
    Task(priority: .background) {
      let userLanguage = UserLocale.getCurrentLanguage()
      var needsTranslation = false

      let recognizer = NLLanguageRecognizer()
      recognizer.languageConstraints = supportedLanguages

      // Process messages in batches to avoid blocking
      for message in messages {
        guard let text = message.message.text, !text.isEmpty else { continue }
        recognizer.processString(text)
      }

      guard let languageCode = recognizer.dominantLanguage?.rawValue,
            let confidence = recognizer.languageHypotheses(withMaximum: 1).first?.value
      else {
        return
      }

      if confidence >= confidenceThreshold {
        if languageCode != userLanguage {
          log.debug("Translation needed: \(languageCode) != \(userLanguage) (confidence: \(confidence))")
          needsTranslation = true
        }
      } else {
        log.debug("Confidence too low (\(confidence)) to determine language")
      }

      log.debug("Translation needed: \(needsTranslation)")
      await publisher.send(needsTranslation)
    }
  }
}
