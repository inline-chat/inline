import Combine
import Logger
import NaturalLanguage

@MainActor
public final class TranslationDetector {
  public static let shared = TranslationDetector()

  // Minimum confidence threshold for language detection (0.0 to 1.0)
  private let confidenceThreshold: Double = 0.3

  // Supported languages for detection
  private let supportedLanguages: [NLLanguage] = [
    .traditionalChinese,
    .simplifiedChinese,
    .english,
    .persian,
  ]

  public struct DetectionResult {
    public let peer: Peer
    public let needsTranslation: Bool
    public let detectedLanguages: [(language: String, confidence: Double)]
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
      let recognizer = NLLanguageRecognizer()
      recognizer.languageConstraints = supportedLanguages
      recognizer.languageHints = [
        .english: 0.8,
        .traditionalChinese: 0.5,
      ]

      // Process messages one by one until we find a different language
      for message in messages {
        guard let text = message.message.text, !text.isEmpty else { continue }

        let cleanedText = LanguageDetector.cleanText(text)
        recognizer.processString(cleanedText)

        // Get language hypotheses for current message
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
          .filter { $0.value >= confidenceThreshold }
          .map { (language: $0.key.rawValue, confidence: $0.value) }

        // If we found a message in a different language, stop and publish true
        if hypotheses.contains(where: { $0.language != userLanguage }) {
          log.debug("Found message in different language: \(hypotheses)")
          log.debug("Translation needed: true")

          publisher.send(DetectionResult(
            peer: peer,
            needsTranslation: true,
            detectedLanguages: hypotheses
          ))
          return
        }
      }

      // If we get here, all messages were in the user's language
      log.debug("All messages in user's language")
      log.debug("Translation needed: false")

      publisher.send(DetectionResult(
        peer: peer,
        needsTranslation: false,
        detectedLanguages: []
      ))
    }
  }
}
