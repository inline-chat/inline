import Combine
import Foundation
import Logger

@MainActor
public final class MessageActionInteractionState {
  public static let shared = MessageActionInteractionState()

  public struct LoadingKey: Hashable, Sendable {
    public let peerId: Peer
    public let messageId: Int64
    public let rev: Int64
    public let actionId: String

    public init(peerId: Peer, messageId: Int64, rev: Int64, actionId: String) {
      self.peerId = peerId
      self.messageId = messageId
      self.rev = rev
      self.actionId = actionId.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  public struct AnswerEvent: Sendable {
    public let key: LoadingKey
    public let interactionId: Int64
    public let toastText: String?

    public init(key: LoadingKey, interactionId: Int64, toastText: String?) {
      self.key = key
      self.interactionId = interactionId
      self.toastText = toastText
    }
  }

  public let loadingPublisher = CurrentValueSubject<Set<LoadingKey>, Never>([])
  public let answeredPublisher = PassthroughSubject<AnswerEvent, Never>()

  private let log = Log.scoped("MessageActionInteractionState")

  private struct PendingFinish: Sendable {
    let toastText: String?
  }

  private var loading: Set<LoadingKey> = []
  private var keyByInteraction: [Int64: LoadingKey] = [:]
  private var interactionByKey: [LoadingKey: Int64] = [:]
  private var pendingFinishByInteraction: [Int64: PendingFinish] = [:]

  init() {}

  @discardableResult
  public func begin(key: LoadingKey) -> Bool {
    guard !key.actionId.isEmpty else {
      return false
    }

    guard !loading.contains(key) else {
      return false
    }

    loading.insert(key)
    loadingPublisher.send(loading)
    return true
  }

  public func attachInteractionId(_ interactionId: Int64, for key: LoadingKey) {
    guard interactionId > 0 else {
      return
    }

    if let previousKey = keyByInteraction[interactionId], previousKey != key {
      interactionByKey.removeValue(forKey: previousKey)
      loading.remove(previousKey)
    }

    keyByInteraction[interactionId] = key
    interactionByKey[key] = interactionId
    loading.insert(key)
    loadingPublisher.send(loading)

    if let pendingFinish = pendingFinishByInteraction.removeValue(forKey: interactionId) {
      complete(interactionId: interactionId, key: key, toastText: pendingFinish.toastText)
    }
  }

  public func finish(interactionId: Int64, toastText: String? = nil) {
    guard interactionId > 0 else {
      return
    }

    guard let key = keyByInteraction[interactionId] else {
      pendingFinishByInteraction[interactionId] = PendingFinish(toastText: toastText)
      log.trace("Buffered finish for interaction \(interactionId) before mapping was attached")
      return
    }

    complete(interactionId: interactionId, key: key, toastText: toastText)
  }

  public func fail(key: LoadingKey) {
    if let interactionId = interactionByKey.removeValue(forKey: key) {
      keyByInteraction.removeValue(forKey: interactionId)
      pendingFinishByInteraction.removeValue(forKey: interactionId)
    }

    if loading.remove(key) != nil {
      loadingPublisher.send(loading)
    }
  }

  public func isLoading(key: LoadingKey) -> Bool {
    loading.contains(key)
  }

  public func loadingActionIds(peerId: Peer, messageId: Int64, rev: Int64) -> Set<String> {
    Set(
      loading
        .filter { $0.peerId == peerId && $0.messageId == messageId && $0.rev == rev }
        .map(\.actionId)
    )
  }

  private func complete(interactionId: Int64, key: LoadingKey, toastText: String?) {
    keyByInteraction.removeValue(forKey: interactionId)
    interactionByKey.removeValue(forKey: key)
    loading.remove(key)
    loadingPublisher.send(loading)

    answeredPublisher.send(
      AnswerEvent(
        key: key,
        interactionId: interactionId,
        toastText: toastText
      )
    )
  }
}
