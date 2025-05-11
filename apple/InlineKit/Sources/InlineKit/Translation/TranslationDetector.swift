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

      // Process all messages
      for message in messages {
        guard let text = message.message.text, !text.isEmpty else { continue }
        let cleanedText = LanguageDetector.cleanText(text)
        recognizer.processString(cleanedText)
      }

      // Get language hypotheses
      let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        .filter { $0.value >= confidenceThreshold }
        .map { (language: $0.key.rawValue, confidence: $0.value) }

      // Check if any detected language is different from user's language
      let needsTranslation = hypotheses.contains { $0.language != userLanguage }

      if needsTranslation {
        log.debug("Found languages: \(hypotheses)")
        log.debug("Translation needed: true")
      } else {
        log.debug("No messages found in other languages")
        log.debug("Translation needed: false")
      }

      publisher.send(DetectionResult(
        peer: peer,
        needsTranslation: needsTranslation,
        detectedLanguages: hypotheses
      ))
    }
  }
}
