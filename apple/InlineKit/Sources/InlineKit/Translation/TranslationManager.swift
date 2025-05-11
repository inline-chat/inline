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
  private var translationTask: Task<Void, Never>?

  private init() {}

  /// Request translations for a set of messages
  /// - Parameters:
  ///   - messages: Messages to check for translation
  ///   - chatId: ID of the chat containing the messages
  ///   - peerId: Peer ID for the chat
  func requestTranslations(messages: [Message], chatId: Int64, peerId: Peer) async {
    // Cancel any existing translation task
    translationTask?.cancel()

    // Create new task with debounce
    translationTask = Task {
      do {
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
        guard !Task.isCancelled else { return }

        // Get user's preferred language
        let targetLanguage = UserLocale.getCurrentLanguage()

        // Filter messages that need translation
        let messagesNeedingTranslation = try await filterMessagesNeedingTranslation(
          messages: messages,
          targetLanguage: targetLanguage
        )

        guard !messagesNeedingTranslation.isEmpty else { return }

        // Create translation request
        var input = TranslateMessagesInput()
        input.peerID = peerId.toInputPeer()
        input.messageIds = messagesNeedingTranslation.map(\.messageId)
        input.language = targetLanguage

        // Call translation API
        try await realtime.invokeWithHandler(.translateMessages, input: .translateMessages(input))

      } catch {
        log.error("Failed to request translations", error: error)
      }
    }
  }

  /// Filter messages that need translation
  private func filterMessagesNeedingTranslation(
    messages: [Message],
    targetLanguage: String
  ) async throws -> [Message] {
    try await db.dbWriter.read { db in
      var messagesNeedingTranslation: [Message] = []

      for message in messages {
        // Skip if no text content
        guard let text = message.text, !text.isEmpty else { continue }

        // Check if translation already exists
        let existingTranslation = try Translation
          .filter(Column("messageId") == message.messageId)
          .filter(Column("chatId") == message.chatId)
          .filter(Column("language") == targetLanguage)
          .fetchOne(db)

        if existingTranslation == nil {
          // Detect message language
          if let detectedLanguage = LanguageDetector.detect(text),
             detectedLanguage != targetLanguage
          {
            messagesNeedingTranslation.append(message)
          }
        }
      }

      return messagesNeedingTranslation
    }
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
