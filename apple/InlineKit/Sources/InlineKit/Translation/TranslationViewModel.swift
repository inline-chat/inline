import Combine
import Foundation
import InlineProtocol
import Logger

actor TranslationViewModel {
  private let db = AppDatabase.shared
  private let realtime = Realtime.shared
  private let log = Log.scoped("TranslationViewModel")
  private var cancellables = Set<AnyCancellable>()

  private let peerId: Peer

  // Combined state management
  private var processedMessages: [Int64: String] = [:] // messageId -> targetLanguage
  private var inProgressRequests: [InProgressRequest: RequestState] = [:]

  // Timeout configuration
  private let requestTimeout: TimeInterval = 20 // 20 seconds timeout

  private struct InProgressRequest: Hashable {
    let peerId: Peer
    let messageIds: Set<Int64>
    let targetLanguage: String
  }

  private struct RequestState {
    let request: InProgressRequest
    let startTime: Date
    let timeoutTask: Task<Void, Never>
  }

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
    Task(priority: .userInitiated) {
      do {
        // Check if this exact request is already in progress
        let requestMessageIds = messagesCopy.map(\.id)
        if await isRequestInProgress(messageIds: requestMessageIds, targetLanguage: targetLanguage) {
          log.debug("Translation request already in progress for these messages")
          return
        }

        // Filter out messages we've already processed for this language
        var newMessages: [FullMessage] = []
        for message in messagesCopy {
          let isProcessed = await isProcessed(messageId: message.id, targetLanguage: targetLanguage)
          if !isProcessed {
            newMessages.append(message)
          }
        }

        guard !newMessages.isEmpty else {
          log.debug("No new messages need translation processing")
          return
        }

        log.debug("Found \(newMessages.count) new messages to process for translation")

        // Mark this request as in progress with start time
        await addRequest(messageIds: requestMessageIds, targetLanguage: targetLanguage)

        // Use defer to ensure cleanup happens even if errors occur
        let cleanupMessageIds = requestMessageIds
        let cleanupNewMessages = newMessages
        defer {
          Task {
            // First remove from translating state to ensure UI is updated
            await TranslatingStatePublisher.shared.removeBatch(
              messageIds: cleanupMessageIds,
              peerId: self.peerId
            )
            // Then clean up our internal state
            await self.removeRequest(messageIds: cleanupMessageIds, targetLanguage: targetLanguage)
            await self.markAsProcessed(messageIds: cleanupNewMessages.map(\.id), targetLanguage: targetLanguage)
          }
        }

        // 1. Filter messages needing translation
        let messagesNeedingTranslation = try await TranslationManager.shared.filterMessagesNeedingTranslation(
          messages: newMessages.map(\.message),
          targetLanguage: targetLanguage
        )

        guard !messagesNeedingTranslation.isEmpty else {
          log.debug("No messages need translation")
          return
        }

        log.debug("Found \(messagesNeedingTranslation.count) messages needing translation")

        // 2. Mark messages as being translated (batch operation)
        let messageIds = messagesNeedingTranslation.map(\.messageId)
        await TranslatingStatePublisher.shared.addBatch(
          messageIds: messageIds,
          peerId: peerId
        )

        // 3. Request translations from API with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
          // Add the main translation request
          group.addTask {
            try await TranslationManager.shared.requestTranslations(
              messages: messagesNeedingTranslation,
              chatId: messagesNeedingTranslation[0].chatId,
              peerId: self.peerId
            )
          }

          // Add timeout task
          group.addTask {
            try await Task.sleep(nanoseconds: UInt64(self.requestTimeout * 1_000_000_000))
            throw TranslationError.timeout
          }

          // Wait for either completion or timeout
          try await group.next()
          group.cancelAll()
        }

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

  // MARK: - State Management Methods

  private func isProcessed(messageId: Int64, targetLanguage: String) -> Bool {
    if let processedLanguage = processedMessages[messageId] {
      return processedLanguage == targetLanguage
    }
    return false
  }

  private func markAsProcessed(messageIds: [Int64], targetLanguage: String) {
    for messageId in messageIds {
      processedMessages[messageId] = targetLanguage
    }
  }

  private func isRequestInProgress(messageIds: [Int64], targetLanguage: String) -> Bool {
    let request = InProgressRequest(
      peerId: peerId,
      messageIds: Set(messageIds),
      targetLanguage: targetLanguage
    )
    return inProgressRequests[request] != nil
  }

  private func addRequest(messageIds: [Int64], targetLanguage: String) {
    let request = InProgressRequest(
      peerId: peerId,
      messageIds: Set(messageIds),
      targetLanguage: targetLanguage
    )

    // Start timeout task
    let timeoutTask = Task {
      try? await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000))
      await handleTimeout(for: request)
    }

    inProgressRequests[request] = RequestState(
      request: request,
      startTime: Date(),
      timeoutTask: timeoutTask
    )
  }

  private func removeRequest(messageIds: [Int64], targetLanguage: String) {
    let request = InProgressRequest(
      peerId: peerId,
      messageIds: Set(messageIds),
      targetLanguage: targetLanguage
    )

    if let state = inProgressRequests[request] {
      state.timeoutTask.cancel()
    }
    inProgressRequests.removeValue(forKey: request)
  }

  private func handleTimeout(for request: InProgressRequest) {
    log.error("Translation request timed out after \(requestTimeout) seconds for messages: \(request.messageIds)")
    if let state = inProgressRequests[request] {
      state.timeoutTask.cancel()
    }
    inProgressRequests.removeValue(forKey: request)

    // Clean up translating state
    Task {
      await TranslatingStatePublisher.shared.removeBatch(
        messageIds: Array(request.messageIds),
        peerId: request.peerId
      )
    }
  }
}

// MARK: - Errors

enum TranslationError: Error {
  case timeout
}

@MainActor
public final class TranslatingStatePublisher {
  public static let shared = TranslatingStatePublisher()

  public actor TranslatingStateHolder {
    public struct Translating: Hashable, Sendable {
      public let messageId: Int64
      public let peerId: Peer
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
      log.debug("Added batch of \(messageIds.count) messages to translating state")
      await publisher.send(currentState)
    }
  }

  public func removeBatch(messageIds: [Int64], peerId: Peer) {
    Task {
      await state.removeBatch(messageIds: messageIds, peerId: peerId)
      let currentState = await state.translating
      log.debug("Removed batch of \(messageIds.count) messages from translating state")
      await publisher.send(currentState)
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
