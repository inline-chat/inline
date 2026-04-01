import Foundation
import Testing
import InlineKit

@testable import Translation

@Suite("Translation Reliability")
struct TranslationReliabilityTests {
  @Test("request bookkeeping uses server message ids for translating state cleanup")
  func requestBookkeepingUsesServerMessageIds() {
    let translatedMessage = makeFullMessage(globalId: 999, messageId: 41, text: "你好")

    let bookkeeping = TranslationRequestBookkeeping(
      candidateMessages: [translatedMessage],
      messagesNeedingTranslation: [translatedMessage.message]
    )

    #expect(bookkeeping.requestMessageIds == [41])
    #expect(
      bookkeeping.processedMessageKeys(outcome: .requestSucceeded) == [
        TranslationMessageKey(messageId: 41, rev: 0),
      ]
    )
  }

  @Test("failed translation requests leave requested messages retryable")
  func failedRequestsLeaveRequestedMessagesRetryable() {
    let translatedMessage = makeFullMessage(globalId: 999, messageId: 41, text: "你好")
    let alreadyTargetLanguage = makeFullMessage(globalId: 1001, messageId: 42, text: "hello")

    let bookkeeping = TranslationRequestBookkeeping(
      candidateMessages: [translatedMessage, alreadyTargetLanguage],
      messagesNeedingTranslation: [translatedMessage.message]
    )

    #expect(
      bookkeeping.processedMessageKeys(outcome: .requestFailed) == [
        TranslationMessageKey(messageId: 42, rev: 0),
      ]
    )
  }

  @MainActor
  @Test("translation state subscriptions only fire for the subscribed peer")
  func translationStateSubscriptionsArePeerScoped() {
    let state = TranslationState.shared
    let peer = Peer.thread(id: 1)
    let otherPeer = Peer.thread(id: 2)
    let key = "translation-reliability-tests"
    var received: [Bool] = []

    state.subscribe(peerId: peer, key: key) { enabled in
      received.append(enabled)
    }
    defer {
      state.unsubscribe(peerId: peer, key: key)
    }

    state.subject.send((otherPeer, false))
    #expect(received.isEmpty)

    state.subject.send((peer, true))
    #expect(received == [true])
  }
}

private func makeFullMessage(globalId: Int64? = nil, messageId: Int64, text: String?) -> FullMessage {
  var message = Message(
    messageId: messageId,
    fromId: 1,
    date: Date(timeIntervalSince1970: 0),
    text: text,
    peerUserId: 2,
    peerThreadId: nil,
    chatId: 10
  )
  message.globalId = globalId

  return FullMessage(
    senderInfo: nil,
    message: message,
    reactions: [],
    repliedToMessage: nil,
    attachments: []
  )
}
