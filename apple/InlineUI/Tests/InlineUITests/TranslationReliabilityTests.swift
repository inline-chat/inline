import Foundation
import Testing
import InlineKit
import InlineProtocol

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

  @Test("language detector strips links before detection")
  func languageDetectorStripsLinks() {
    let cleaned = LanguageDetector.cleanText(
      "Check https://inline.chat/docs inline.chat/help www.example.com/path mo@inline.chat @mo"
    )

    #expect(cleaned == "Check")
  }

  @Test("link-only messages do not produce detected languages")
  func linkOnlyMessagesDoNotProduceDetectedLanguages() {
    #expect(LanguageDetector.advancedDetect("inline.chat/help") == [])
    #expect(LanguageDetector.advancedDetect("www.example.com/path") == [])
  }

  @Test("full message translation accessors do not fall back to original content when disabled")
  func fullMessageTranslationAccessorsDoNotFallbackWhenDisabled() {
    let peerId = Int64(91_001)
    let message = makeFullMessage(
      messageId: 91,
      text: "`original`",
      peerUserId: peerId,
      translationText: "Translated text",
      translationEntities: nil
    )

    TranslationState.shared.setTranslationEnabled(false, for: .user(id: peerId))
    defer { TranslationState.shared.setTranslationEnabled(false, for: .user(id: peerId)) }

    #expect(message.translationText == nil)
    #expect(message.translationEntities == nil)
    #expect(message.isTranslated == false)
    #expect(message.displayText == "`original`")
  }

  @Test("full message translation entities are empty when translated text has no entities")
  func fullMessageTranslationEntitiesAreEmptyForEntitylessTranslations() {
    let peerId = Int64(91_002)
    let message = makeFullMessage(
      messageId: 92,
      text: "`original`",
      peerUserId: peerId,
      translationText: "plain translated",
      translationEntities: nil
    )

    TranslationState.shared.setTranslationEnabled(true, for: .user(id: peerId))
    defer { TranslationState.shared.setTranslationEnabled(false, for: .user(id: peerId)) }

    #expect(message.translationText == "plain translated")
    #expect(message.translationEntities?.entities.isEmpty == true)
    #expect(message.isTranslated == true)
    #expect(message.displayText == "plain translated")
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

private func makeFullMessage(
  globalId: Int64? = nil,
  messageId: Int64,
  text: String?,
  peerUserId: Int64 = 2,
  translationText: String? = nil,
  translationEntities: MessageEntities? = nil
) -> FullMessage {
  var message = Message(
    messageId: messageId,
    fromId: 1,
    date: Date(timeIntervalSince1970: 0),
    text: text,
    peerUserId: peerUserId,
    peerThreadId: nil,
    chatId: 10
  )
  message.globalId = globalId
  message.entities = makeCodeEntities(for: text)

  let translations = translationText.map {
    Translation(
      messageId: messageId,
      chatId: message.chatId,
      translation: $0,
      entities: translationEntities,
      language: UserLocale.getCurrentLanguage(),
      date: Date(timeIntervalSince1970: 0),
      msgRev: message.rev
    )
  }.map { [$0] } ?? []

  return FullMessage(
    senderInfo: nil,
    message: message,
    reactions: [],
    repliedToMessage: nil,
    attachments: [],
    translations: translations
  )
}

private func makeCodeEntities(for text: String?) -> MessageEntities? {
  guard let text,
        let start = text.firstIndex(of: "`"),
        let end = text.lastIndex(of: "`"),
        start != end
  else {
    return nil
  }

  var entity = MessageEntity()
  entity.type = .code
  entity.offset = Int32(text.distance(from: text.startIndex, to: text.index(after: start)))
  entity.length = Int32(text.distance(from: text.index(after: start), to: end))

  var entities = MessageEntities()
  entities.entities = [entity]
  return entities
}
