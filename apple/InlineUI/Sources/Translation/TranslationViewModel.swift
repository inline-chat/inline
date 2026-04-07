import Combine
import Foundation
import InlineKit
import Logger

private let translationRequestTimeout: TimeInterval = 20

public actor TranslationViewModel {
  private let log = Log.scoped("TranslationViewModel")

  private let peerId: Peer

  // Combined state management
  private var processedMessages: [TranslationMessageKey: String] = [:] // messageKey -> targetLanguage
  private var inProgressRequests = Set<InProgressRequest>()

  private struct InProgressRequest: Hashable {
    let peerId: Peer
    let messageIds: Set<Int64>
    let targetLanguage: String
  }

  public init(peerId: Peer) {
    self.peerId = peerId

    // Subscribe to translation state changes
    Task { @MainActor in
      TranslationState.shared.subscribe(peerId: peerId, key: "translationViewModel") { [weak self] enabled in
        Task {
          await self?.translationStateChanged(enabled: enabled)
        }
      }
    }
  }

  deinit {
    let peerId = self.peerId
    Task { @MainActor in
      TranslationState.shared.unsubscribe(peerId: peerId, key: "translationViewModel")
    }
  }

  private func translationStateChanged(enabled: Bool) async {
    log.trace("Translation state changed to \(enabled) for peer \(peerId)")
    if !enabled {
      await resetState()
    }
  }

  private func resetState() async {
    processedMessages.removeAll()
    inProgressRequests.removeAll()
    await TranslatingStatePublisher.shared.removeForPeer(peerId: peerId)
  }

  public nonisolated func messagesDisplayed(messages: [FullMessage]) {
    log.trace("Processing \(messages.count) messages for translation, peer: \(peerId)")

    // Check if translation is enabled for this peer
    guard TranslationState.shared.isTranslationEnabled(for: peerId) else {
      log.trace("Translation disabled for peer \(peerId)")
      return
    }

    // Get user's preferred language
    let targetLanguage = UserLocale.getCurrentLanguage()
    log.trace("Target language: \(targetLanguage)")

    // Create a copy of messages to avoid data races
    let messagesCopy = messages

    // Do everything on a background thread to avoid impacting UI
    Task(priority: .userInitiated) {
      do {
        // Filter out messages we've already processed for this language
        var newMessages: [FullMessage] = []
        for message in messagesCopy {
          // Skip sending/failed messages
          if message.message.status == .sending || message.message.status == .failed {
            continue
          }
          let isProcessed = await isProcessed(message: message, targetLanguage: targetLanguage)
          if !isProcessed {
            newMessages.append(message)
          }
        }

        guard !newMessages.isEmpty else {
          log.trace("No new messages need translation processing")
          return
        }

        log.trace("Found \(newMessages.count) new messages to process for translation")

        // 1. Filter messages needing translation
        let messagesNeedingTranslation = try await TranslationManager.shared.filterMessagesNeedingTranslation(
          messages: newMessages,
          targetLanguage: targetLanguage
        )

        let bookkeeping = TranslationRequestBookkeeping(
          candidateMessages: newMessages,
          messagesNeedingTranslation: messagesNeedingTranslation
        )

        guard !bookkeeping.requestMessageIds.isEmpty else {
          log.trace("No messages need translation")
          await markAsProcessed(keys: bookkeeping.processedMessageKeys(outcome: .notRequested), targetLanguage: targetLanguage)
          return
        }

        let request = InProgressRequest(
          peerId: peerId,
          messageIds: Set(bookkeeping.requestMessageIds),
          targetLanguage: targetLanguage
        )

        if await isRequestInProgress(request) {
          log.trace("Translation request already in progress for these messages")
          return
        }

        log.trace("Found \(bookkeeping.requestMessageIds.count) messages needing translation")

        // Mark this request as in progress
        await addRequest(request)

        // 2. Mark messages as being translated (batch operation)
        await TranslatingStatePublisher.shared.addBatch(
          messageIds: bookkeeping.requestMessageIds,
          peerId: peerId
        )

        // 3. Request translations from API with timeout
        do {
          try await performTranslationRequestWithTimeout {
            try await TranslationManager.shared.requestTranslations(
              messages: messagesNeedingTranslation,
              chatId: messagesNeedingTranslation[0].chatId,
              peerId: self.peerId
            )
          }

          log.trace("Successfully requested translations for \(bookkeeping.requestMessageIds.count) messages")

          await finalizeRequest(
            request,
            bookkeeping: bookkeeping,
            targetLanguage: targetLanguage,
            outcome: .requestSucceeded
          )

          // 5. Trigger message updates
          for message in messagesNeedingTranslation {
            await MessagesPublisher.shared.messageUpdated(
              message: message,
              peer: peerId,
              animated: true
            )
          }

          log.trace("Completed translation cycle for \(bookkeeping.requestMessageIds.count) messages")
        } catch {
          log.error("Failed to process translations", error: error)
          await finalizeRequest(
            request,
            bookkeeping: bookkeeping,
            targetLanguage: targetLanguage,
            outcome: .requestFailed
          )
        }
      } catch {
        log.error("Failed to process translations", error: error)
      }
    }
  }

  // MARK: - Static Translation Method

  /// Simple static method to translate messages for a given peer
  /// - Parameters:
  ///   - peerId: The peer ID to translate messages for
  ///   - messages: Array of messages to check for translation
  public nonisolated static func translateMessages(for peerId: Peer, messages: [FullMessage]) {
    let log = Log.scoped("TranslationViewModel")

    log.trace("Processing \(messages.count) messages for translation, peer: \(peerId)")

    // Check if translation is enabled for this peer
    guard TranslationState.shared.isTranslationEnabled(for: peerId) else {
      log.trace("Translation disabled for peer \(peerId)")
      return
    }

    // Get user's preferred language
    let targetLanguage = UserLocale.getCurrentLanguage()
    log.trace("Target language: \(targetLanguage)")

    // Do everything on a background thread to avoid impacting UI
    Task(priority: .userInitiated) {
      do {
        // Filter out sending/failed messages
        let validMessages = messages.filter { message in
          message.message.status != .sending && message.message.status != .failed
        }

        guard !validMessages.isEmpty else {
          log.trace("No valid messages to process for translation")
          return
        }

        // Filter messages needing translation
        let messagesNeedingTranslation = try await TranslationManager.shared.filterMessagesNeedingTranslation(
          messages: validMessages,
          targetLanguage: targetLanguage
        )

        guard !messagesNeedingTranslation.isEmpty else {
          log.trace("No messages need translation")
          return
        }

        log.trace("Found \(messagesNeedingTranslation.count) messages needing translation")

        // Mark messages as being translated
        let messageIds = messagesNeedingTranslation.map(\.messageId)
        await TranslatingStatePublisher.shared.addBatch(
          messageIds: messageIds,
          peerId: peerId
        )

        // Request translations from API
        try await performTranslationRequestWithTimeout {
          try await TranslationManager.shared.requestTranslations(
            messages: messagesNeedingTranslation,
            chatId: messagesNeedingTranslation[0].chatId,
            peerId: peerId
          )
        }

        log.trace("Successfully requested translations for \(messageIds.count) messages")

        // Remove messages from translating state
        await TranslatingStatePublisher.shared.removeBatch(
          messageIds: messageIds,
          peerId: peerId
        )

        // Trigger message updates
        for message in messagesNeedingTranslation {
          await MessagesPublisher.shared.messageUpdated(
            message: message,
            peer: peerId,
            animated: true
          )
        }

        log.trace("Completed translation cycle for \(messageIds.count) messages")
      } catch {
        log.error("Failed to process translations", error: error)
        // Clean up translating state in case of error
        let messageIds = messages.map(\.message.messageId)
        await TranslatingStatePublisher.shared.removeBatch(
          messageIds: messageIds,
          peerId: peerId
        )
      }
    }
  }

  // MARK: - State Management Methods

  private func isProcessed(message: FullMessage, targetLanguage: String) -> Bool {
    let messageKey = TranslationMessageKey.from(message)
    if let processedLanguage = processedMessages[messageKey] {
      return processedLanguage == targetLanguage
    }
    return false
  }

  private func markAsProcessed(keys: [TranslationMessageKey], targetLanguage: String) {
    for key in keys {
      processedMessages[key] = targetLanguage
    }
  }

  private func isRequestInProgress(_ request: InProgressRequest) -> Bool {
    inProgressRequests.contains(request)
  }

  private func addRequest(_ request: InProgressRequest) {
    inProgressRequests.insert(request)
  }

  private func removeRequest(_ request: InProgressRequest) {
    inProgressRequests.remove(request)
  }

  private func finalizeRequest(
    _ request: InProgressRequest,
    bookkeeping: TranslationRequestBookkeeping,
    targetLanguage: String,
    outcome: TranslationRequestOutcome
  ) async {
    await TranslatingStatePublisher.shared.removeBatch(
      messageIds: bookkeeping.requestMessageIds,
      peerId: request.peerId
    )
    removeRequest(request)
    markAsProcessed(keys: bookkeeping.processedMessageKeys(outcome: outcome), targetLanguage: targetLanguage)
  }
}

// MARK: - Errors

enum TranslationError: Error {
  case timeout
}

private func performTranslationRequestWithTimeout(
  seconds: TimeInterval = translationRequestTimeout,
  operation: @escaping @Sendable () async throws -> Void
) async throws {
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      try await operation()
    }

    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw TranslationError.timeout
    }

    defer {
      group.cancelAll()
    }

    guard let result = try await group.next() else {
      throw TranslationError.timeout
    }
    return result
  }
}

@MainActor
public final class TranslatingStatePublisher {
  public static let shared = TranslatingStatePublisher()

  public actor TranslatingStateHolder {
    public struct Translating: Hashable, Sendable {
      public let messageId: Int64
      public let peerId: Peer

      public init(messageId: Int64, peerId: Peer) {
        self.messageId = messageId
        self.peerId = peerId
      }
    }

    public var translating: Set<Translating> = []

    public func addBatch(messageIds: [Int64], peerId: Peer) {
      let newItems = Set(messageIds.map { Translating(messageId: $0, peerId: peerId) })
      translating.formUnion(newItems)
    }

    public func removeBatch(messageIds: [Int64], peerId: Peer) {
      let itemsToRemove = Set(messageIds.map { Translating(messageId: $0, peerId: peerId) })
      translating.subtract(itemsToRemove)
    }

    public func removeForPeer(peerId: Peer) {
      for item in translating {
        if item.peerId == peerId {
          translating.remove(item)
        }
      }
    }

    public func isTranslating(messageId: Int64, peerId: Peer) -> Bool {
      translating.contains(Translating(messageId: messageId, peerId: peerId))
    }
  }

  private let state = TranslatingStateHolder()
  private let log = Log.scoped("TranslatingStatePublisher")

  private init() {}

  public let publisher = CurrentValueSubject<Set<TranslatingStateHolder.Translating>, Never>([])

  public func addBatch(messageIds: [Int64], peerId: Peer) {
    Task {
      await state.addBatch(messageIds: messageIds, peerId: peerId)
      let currentState = await state.translating
      log.trace("Added batch of \(messageIds.count) messages to translating state")
      publisher.send(currentState)
    }
  }

  public func removeBatch(messageIds: [Int64], peerId: Peer) {
    Task {
      await state.removeBatch(messageIds: messageIds, peerId: peerId)
      let currentState = await state.translating
      log.trace("Removed batch of \(messageIds.count) messages from translating state")
      publisher.send(currentState)
    }
  }

  public func removeForPeer(peerId: Peer) {
    Task {
      await state.removeForPeer(peerId: peerId)
      let currentState = await state.translating
      log.trace("Removed \(currentState.count) messages for peer \(peerId) from translating state")
      publisher.send(currentState)
    }
  }

  // Keep individual methods for backward compatibility
  public func add(messageId: Int64, peerId: Peer) {
    addBatch(messageIds: [messageId], peerId: peerId)
  }

  public func remove(messageId: Int64, peerId: Peer) {
    removeBatch(messageIds: [messageId], peerId: peerId)
  }

  public func isTranslating(messageId: Int64, peerId: Peer) -> Bool {
    publisher.value.contains(TranslatingStateHolder.Translating(messageId: messageId, peerId: peerId))
  }
}
