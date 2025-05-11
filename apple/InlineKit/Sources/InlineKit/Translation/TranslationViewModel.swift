import Combine
import InlineProtocol
import Logger

// Cache actor to manage processed messages state
private actor TranslationCache {
  // Key: messageId, Value: target language
  private var processedMessages: [Int64: String] = [:]

  func isProcessed(messageId: Int64, targetLanguage: String) -> Bool {
    if let processedLanguage = processedMessages[messageId] {
      return processedLanguage == targetLanguage
    }
    return false
  }

  func markAsProcessed(messageIds: [Int64], targetLanguage: String) {
    for messageId in messageIds {
      processedMessages[messageId] = targetLanguage
    }
  }
}

actor TranslationViewModel {
  private let db = AppDatabase.shared
  private let realtime = Realtime.shared
  private let log = Log.scoped("TranslationViewModel")

  private var cancellables = Set<AnyCancellable>()

  private let peerId: Peer
  private let cache = TranslationCache()

  init(peerId: Peer) {
    self.peerId = peerId
  }

  nonisolated func messagesDisplayed(messages: [FullMessage]) {
    log.debug("Processing \(messages.count) messages for translation, peer: \(peerId)")

    // Check if translation is enabled for this peer
    guard TranslationState.shared.isTranslationEnabled(for: peerId) else {
      log.debug("Translation disabled for peer \(peerId)")
      return
    }

    // Get user's preferred language
    let targetLanguage = UserLocale.getCurrentLanguage()
    log.debug("Target language: \(targetLanguage)")

    // Create a copy of messages to avoid data races
    let messagesCopy = messages

    // Do everything on a background thread to avoid impacting UI
    Task(priority: .background) {
      do {
        // Filter out messages we've already processed for this language
        var newMessages: [FullMessage] = []
        for message in messagesCopy {
          let isProcessed = await cache.isProcessed(
            messageId: message.id,
            targetLanguage: targetLanguage
          )
          if !isProcessed {
            newMessages.append(message)
          }
        }

        guard !newMessages.isEmpty else {
          log.debug("No new messages need translation processing")
          return
        }

        log.debug("Found \(newMessages.count) new messages to process for translation")

        // 1. Filter messages needing translation
        let messagesNeedingTranslation = try await TranslationManager.shared.filterMessagesNeedingTranslation(
          messages: newMessages.map(\.message),
          targetLanguage: targetLanguage
        )

        guard !messagesNeedingTranslation.isEmpty else {
          log.debug("No messages need translation")
          // Mark all messages as processed even if they don't need translation
          await cache.markAsProcessed(
            messageIds: newMessages.map(\.id),
            targetLanguage: targetLanguage
          )
          return
        }

        log.debug("Found \(messagesNeedingTranslation.count) messages needing translation")

        // 2. Mark messages as being translated (batch operation)
        let messageIds = messagesNeedingTranslation.map(\.messageId)
        await TranslatingStatePublisher.shared.addBatch(
          messageIds: messageIds,
          peerId: peerId
        )

        // 3. Request translations from API
        try await TranslationManager.shared.requestTranslations(
          messages: messagesNeedingTranslation,
          chatId: messagesNeedingTranslation[0].chatId,
          peerId: peerId
        )

        log.debug("Successfully requested translations for \(messageIds.count) messages")

        // 4. Remove messages from translating state (batch operation)
        await TranslatingStatePublisher.shared.removeBatch(
          messageIds: messageIds,
          peerId: peerId
        )

        // 5. Trigger message updates
        for message in messagesNeedingTranslation {
          await MessagesPublisher.shared.messageUpdated(
            message: message,
            peer: peerId,
            animated: true
          )
        }

        // Mark all processed messages with current language
        await cache.markAsProcessed(
          messageIds: newMessages.map(\.id),
          targetLanguage: targetLanguage
        )

        log.debug("Completed translation cycle for \(messageIds.count) messages")

      } catch {
        log.error("Failed to process translations", error: error)
        // Clean up translating state in case of error
        let messageIds = messagesCopy.map(\.id)
        await TranslatingStatePublisher.shared.removeBatch(
          messageIds: messageIds,
          peerId: peerId
        )
      }
    }
  }
}

@MainActor
public final class TranslatingStatePublisher {
  public static let shared = TranslatingStatePublisher()

  actor TranslatingStateHolder {
    struct Translating: Hashable {
      let messageId: Int64
      let peerId: Peer
    }

    var translating: Set<Translating> = []

    func addBatch(messageIds: [Int64], peerId: Peer) {
      let newItems = Set(messageIds.map { Translating(messageId: $0, peerId: peerId) })
      translating.formUnion(newItems)
    }

    func removeBatch(messageIds: [Int64], peerId: Peer) {
      let itemsToRemove = Set(messageIds.map { Translating(messageId: $0, peerId: peerId) })
      translating.subtract(itemsToRemove)
    }

    func isTranslating(messageId: Int64, peerId: Peer) -> Bool {
      translating.contains(Translating(messageId: messageId, peerId: peerId))
    }
  }

  private let state = TranslatingStateHolder()
  private let log = Log.scoped("TranslatingStatePublisher")

  private init() {}

  let publisher = CurrentValueSubject<Set<TranslatingStateHolder.Translating>, Never>([])

  func addBatch(messageIds: [Int64], peerId: Peer) {
    Task {
      await state.addBatch(messageIds: messageIds, peerId: peerId)
      let currentState = await state.translating
      log.debug("Added batch of \(messageIds.count) messages to translating state")
      await publisher.send(currentState)
    }
  }

  func removeBatch(messageIds: [Int64], peerId: Peer) {
    Task {
      await state.removeBatch(messageIds: messageIds, peerId: peerId)
      let currentState = await state.translating
      log.debug("Removed batch of \(messageIds.count) messages from translating state")
      await publisher.send(currentState)
    }
  }

  // Keep individual methods for backward compatibility
  func add(messageId: Int64, peerId: Peer) {
    addBatch(messageIds: [messageId], peerId: peerId)
  }

  func remove(messageId: Int64, peerId: Peer) {
    removeBatch(messageIds: [messageId], peerId: peerId)
  }

  func isTranslating(messageId: Int64, peerId: Peer) -> Bool {
    publisher.value.contains(TranslatingStateHolder.Translating(messageId: messageId, peerId: peerId))
  }
}
