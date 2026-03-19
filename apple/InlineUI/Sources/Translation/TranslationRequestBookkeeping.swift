import Foundation
import InlineKit

enum TranslationRequestOutcome: Sendable {
  case notRequested
  case requestSucceeded
  case requestFailed
}

struct TranslationMessageKey: Hashable, Sendable {
  let messageId: Int64
  let editDate: Date?

  init(messageId: Int64, editDate: Date?) {
    self.messageId = messageId
    self.editDate = editDate
  }

  static func from(_ message: FullMessage) -> Self {
    Self(messageId: message.message.messageId, editDate: message.message.editDate)
  }

  static func from(_ message: Message) -> Self {
    Self(messageId: message.messageId, editDate: message.editDate)
  }
}

struct TranslationRequestBookkeeping: Sendable {
  let requestMessageIds: [Int64]
  private let candidateMessageKeys: [TranslationMessageKey]
  private let requestedMessageKeys: Set<TranslationMessageKey>

  init(candidateMessages: [FullMessage], messagesNeedingTranslation: [Message]) {
    candidateMessageKeys = candidateMessages.map(TranslationMessageKey.from)
    requestMessageIds = messagesNeedingTranslation.map(\.messageId)
    requestedMessageKeys = Set(messagesNeedingTranslation.map(TranslationMessageKey.from))
  }

  func processedMessageKeys(outcome: TranslationRequestOutcome) -> [TranslationMessageKey] {
    switch outcome {
      case .notRequested, .requestSucceeded:
        candidateMessageKeys
      case .requestFailed:
        candidateMessageKeys.filter { !requestedMessageKeys.contains($0) }
    }
  }
}
