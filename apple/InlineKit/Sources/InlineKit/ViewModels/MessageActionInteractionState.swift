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
    /// A bot's `alert` response, shown as a dialog.
    public let alert: MessageActionAlertContent?
    /// A bot's `open_url` response, opened if it arrives soon enough after `pressedAt`.
    public let openURL: BotResponseOpenURL?
    /// When the press happened on this device.
    public let pressedAt: Date

    public init(
      key: LoadingKey,
      interactionId: Int64,
      toastText: String?,
      alert: MessageActionAlertContent? = nil,
      openURL: BotResponseOpenURL? = nil,
      pressedAt: Date = Date()
    ) {
      self.key = key
      self.interactionId = interactionId
      self.toastText = toastText
      self.alert = alert
      self.openURL = openURL
      self.pressedAt = pressedAt
    }
  }

  public let loadingPublisher = CurrentValueSubject<Set<LoadingKey>, Never>([])
  public let answeredPublisher = PassthroughSubject<AnswerEvent, Never>()

  private let log = Log.scoped("MessageActionInteractionState")

  private struct PendingFinish: Sendable {
    let toastText: String?
    let alert: MessageActionAlertContent?
    let openURL: BotResponseOpenURL?
  }

  private var loading: Set<LoadingKey> = []
  private var pressedAtByKey: [LoadingKey: Date] = [:]
  private var keyByInteraction: [Int64: LoadingKey] = [:]
  private var interactionByKey: [LoadingKey: Int64] = [:]
  private var pendingFinishByInteraction: [Int64: PendingFinish] = [:]
  /// Oldest first, so the buffer of answers nothing claimed stays bounded.
  private var pendingFinishOrder: [Int64] = []
  private static let maximumPendingFinishes = 64
  /// Answers to agent controls (Stop, Resume), which have no message button to show them.
  private var controlHandlers: [Int64: @MainActor (String?, MessageActionAlertContent?) -> Void] = [:]

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
    pressedAtByKey[key] = Date()
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
      pendingFinishOrder.removeAll { $0 == interactionId }
      complete(
        interactionId: interactionId,
        key: key,
        toastText: pendingFinish.toastText,
        alert: pendingFinish.alert,
        openURL: pendingFinish.openURL
      )
    }
  }

  public func finish(
    interactionId: Int64,
    toastText: String? = nil,
    alert: MessageActionAlertContent? = nil,
    openURL: BotResponseOpenURL? = nil
  ) {
    guard interactionId > 0 else {
      return
    }

    if let handler = controlHandlers.removeValue(forKey: interactionId) {
      handler(toastText, alert)
      return
    }
    guard let key = keyByInteraction[interactionId] else {
      bufferFinish(interactionId, PendingFinish(toastText: toastText, alert: alert, openURL: openURL))
      log.trace("Buffered finish for interaction \(interactionId) before mapping was attached")
      return
    }

    complete(interactionId: interactionId, key: key, toastText: toastText, alert: alert, openURL: openURL)
  }

  /// Shows the bot's answer to an agent control (Stop, Resume) through `handler`: the reply can
  /// arrive before or after the control call returns its interaction.
  public func expectControlAnswer(
    _ interactionId: Int64,
    handler: @escaping @MainActor (String?, MessageActionAlertContent?) -> Void
  ) {
    guard interactionId > 0 else { return }
    if let pending = pendingFinishByInteraction.removeValue(forKey: interactionId) {
      pendingFinishOrder.removeAll { $0 == interactionId }
      handler(pending.toastText, pending.alert)
      return
    }
    controlHandlers[interactionId] = handler
    if controlHandlers.count > Self.maximumPendingFinishes, let oldest = controlHandlers.keys.min() {
      controlHandlers.removeValue(forKey: oldest)
    }
  }

  private func bufferFinish(_ interactionId: Int64, _ finish: PendingFinish) {
    if pendingFinishByInteraction.updateValue(finish, forKey: interactionId) == nil {
      pendingFinishOrder.append(interactionId)
    }
    while pendingFinishOrder.count > Self.maximumPendingFinishes {
      pendingFinishByInteraction.removeValue(forKey: pendingFinishOrder.removeFirst())
    }
  }

  public func fail(key: LoadingKey) {
    if let interactionId = interactionByKey.removeValue(forKey: key) {
      keyByInteraction.removeValue(forKey: interactionId)
      pendingFinishByInteraction.removeValue(forKey: interactionId)
    }

    pressedAtByKey.removeValue(forKey: key)
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

  private func complete(
    interactionId: Int64,
    key: LoadingKey,
    toastText: String?,
    alert: MessageActionAlertContent? = nil,
    openURL: BotResponseOpenURL? = nil
  ) {
    keyByInteraction.removeValue(forKey: interactionId)
    interactionByKey.removeValue(forKey: key)
    loading.remove(key)
    // No press on record (state was reset): too old to open anything.
    let pressedAt = pressedAtByKey.removeValue(forKey: key) ?? .distantPast
    loadingPublisher.send(loading)

    answeredPublisher.send(
      AnswerEvent(
        key: key,
        interactionId: interactionId,
        toastText: toastText,
        alert: alert,
        openURL: openURL,
        pressedAt: pressedAt
      )
    )
  }
}
