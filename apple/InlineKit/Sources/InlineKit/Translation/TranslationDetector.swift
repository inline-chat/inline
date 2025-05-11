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

  public struct DetectionResult {
    let peer: Peer
    let needsTranslation: Bool
  }

  private let log = Log.scoped("TranslationDetector")
  private let publisher = PassthroughSubject<DetectionResult, Never>()

  private init() {}

  /// Publisher that emits true when translation is needed, false otherwise
  public var needsTranslation: AnyPublisher<DetectionResult, Never> {
    publisher.eraseToAnyPublisher()
  }

  /// Analyze messages to detect if translation is needed
  /// - Parameter messages: Array of messages to analyze
  public func analyzeMessages(peer: Peer, messages: [FullMessage]) {
    Task(priority: .background) {
      let userLanguage = UserLocale.getCurrentLanguage()

      // Check messages one by one
      for message in messages {
        guard let text = message.message.text, !text.isEmpty else { continue }

        // Create a new recognizer for each message
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = supportedLanguages

        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)

        // If we found a language with sufficient confidence
        if let detectedLanguage = hypotheses.first,
           detectedLanguage.key.rawValue != userLanguage,
           detectedLanguage.value >= confidenceThreshold
        {
          log
            .debug(
              "Found message in other language: \(detectedLanguage.key.rawValue) with confidence: \(detectedLanguage.value)"
            )
          log.debug("Translation needed: true")
          publisher.send(DetectionResult(peer: peer, needsTranslation: true))
          return
        }
      }

      // If we get here, no messages needed translation
      log.debug("No messages found in other languages")
      log.debug("Translation needed: false")
      publisher.send(DetectionResult(peer: peer, needsTranslation: false))
    }
  }
}
