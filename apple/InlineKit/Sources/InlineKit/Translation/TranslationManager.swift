import Foundation
import GRDB
import InlineProtocol
import Logger

actor TranslationManager {
  static let shared = TranslationManager()
  private let log = Log.scoped("TranslationManager")
  private let db = AppDatabase.shared
  private let realtime = Realtime.shared

  // Cache for pending translation requests to avoid duplicates
  private var pendingTranslations: Set<Int64> = []

  private init() {}

  /// Request translations for a set of messages
  /// - Parameters:
  ///   - messages: Messages to check for translation
  ///   - chatId: ID of the chat containing the messages
  ///   - peerId: Peer ID for the chat
  func requestTranslations(messages: [Message], chatId: Int64, peerId: Peer) async throws {
    // Get user's preferred language
    let targetLanguage = UserLocale.getCurrentLanguage()
    log.debug("Requesting translations for \(messages.count) messages in \(targetLanguage)")

    // Create translation request
    var input = TranslateMessagesInput()
    input.peerID = peerId.toInputPeer()
    input.messageIds = messages.map(\.messageId)
    input.language = targetLanguage

    // Call translation API
    try await realtime.invokeWithHandler(.translateMessages, input: .translateMessages(input))
    log.debug("Successfully sent translation request to API")
  }

  /// Filter messages that need translation
  public func filterMessagesNeedingTranslation(
    messages: [FullMessage],
    targetLanguage: String
  ) async throws -> [Message] {
    log.debug("Filtering \(messages.count) messages for translation needs")

    var messagesNeedingTranslation: [Message] = []

    for fullMessage in messages {
      let message = fullMessage.message

      // Skip if no text content
      guard let text = message.text, !text.isEmpty else { continue }

      // Check if translation already exists using FullMessage's translations
      if fullMessage.translation(for: targetLanguage) != nil {
        // Translation already exists, skip this message
        log.debug("Translation already exists for message \(message.messageId)")
        continue
      }

      // Detect message language outside of DB transaction
      let detectedLanguages = LanguageDetector.advancedDetect(text)
      log.debug("Detected languages: \(detectedLanguages) for message \(message.messageId)")

      // Translate if it contains a language other than the target language
      if detectedLanguages.count > 0, detectedLanguages.contains(where: { $0 != targetLanguage }) {
        messagesNeedingTranslation.append(message)
      }
    }

    log.debug("Found \(messagesNeedingTranslation.count) messages needing translation")
    return messagesNeedingTranslation
  }

  /// Get translation for a message
  func getTranslation(messageId: Int64, chatId: Int64, language: String) async throws -> Translation? {
    try await db.dbWriter.read { db in
      try Translation
        .filter(Column("messageId") == messageId)
        .filter(Column("chatId") == chatId)
        .filter(Column("language") == language)
        .fetchOne(db)
    }
  }
}
