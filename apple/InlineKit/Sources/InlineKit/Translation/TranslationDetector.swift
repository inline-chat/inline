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
      var needsTranslation = false

      let recognizer = NLLanguageRecognizer()
      recognizer.languageConstraints = supportedLanguages

      // Process messages in batches to avoid blocking
      for message in messages {
        guard let text = message.message.text, !text.isEmpty else { continue }
        recognizer.processString(text)
      }

      let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
      guard !hypotheses.isEmpty else {
        return
      }

      // Check if any of the top 2 languages match the user's language
      let matchingHypothesis = hypotheses.first { $0.key.rawValue == userLanguage }

      if let matchingHypothesis {
        // If we found a match with user's language, no translation needed
        log.debug("Found matching language: \(userLanguage) (confidence: \(matchingHypothesis.value))")
        needsTranslation = false
      } else {
        // If no match found, use the most confident language
        if let topHypothesis = hypotheses.first, topHypothesis.value >= confidenceThreshold {
          log
            .debug(
              "Translation needed: \(topHypothesis.key.rawValue) != \(userLanguage) (confidence: \(topHypothesis.value))"
            )
          needsTranslation = true
        } else {
          log.debug("Confidence too low (\(hypotheses.first?.value ?? 0)) to determine language")
        }
      }

      log.debug("Translation needed: \(needsTranslation)")
      publisher.send(DetectionResult(peer: peer, needsTranslation: needsTranslation))
    }
  }
}
