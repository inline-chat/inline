import InlineKit
import UIKit

@MainActor
final class SendMessageAnimationCoordinator {
  private enum PendingState {
    case prepared(SendMessageAnimationSource)
    case animating(
      source: SendMessageAnimationSource,
      preview: SendMessageAnimationPreviewView,
      target: SendMessageAnimationTarget,
      revealTarget: (SendMessageAnimationTarget) -> Void
    )
  }

  private weak var hostView: UIView?
  private weak var sourceLayoutView: UIView?
  private var pendingByIdentity: [SendMessageAnimationIdentity: PendingState] = [:]
  private var identityByStableMessageId: [Int64: SendMessageAnimationIdentity] = [:]
  private var cleanupTasksByIdentity: [SendMessageAnimationIdentity: Task<Void, Never>] = [:]

  init(hostView: UIView? = nil) {
    self.hostView = hostView
    SendMessageAnimationDiagnostics.debug(
      "coordinator init host=\(hostView != nil) pid=\(ProcessInfo.processInfo.processIdentifier)"
    )
  }

  func setHostView(_ hostView: UIView?) {
    self.hostView = hostView
    let frameInWindow = hostView.flatMap { view -> CGRect? in
      guard let window = view.window else { return nil }
      return view.convert(view.bounds, to: window)
    }
    SendMessageAnimationDiagnostics.debug(
      "coordinator host-update host=\(hostView != nil) window=\(hostView?.window != nil) frame=\(frameInWindow.map { "[\(SendMessageAnimationDiagnostics.rect($0))]" } ?? "nil")"
    )
  }

  func setSourceLayoutView(_ sourceLayoutView: UIView?) {
    self.sourceLayoutView = sourceLayoutView
    let frameInWindow = sourceLayoutView.flatMap { view -> CGRect? in
      guard let window = view.window else { return nil }
      return view.convert(view.bounds, to: window)
    }
    SendMessageAnimationDiagnostics.debug(
      "coordinator source-layout-update view=\(sourceLayoutView != nil) window=\(sourceLayoutView?.window != nil) frame=\(frameInWindow.map { "[\(SendMessageAnimationDiagnostics.rect($0))]" } ?? "nil")"
    )
  }

  func canPrepareTextSendSource() -> Bool {
    guard let collectionView = sourceLayoutView as? MessagesCollectionView else {
      return true
    }
    return collectionView.itemsEmpty || collectionView.shouldScrollToBottom
  }

  @discardableResult
  func prepare(source: SendMessageAnimationSource) -> Bool {
    guard source.isUsable else {
      SendMessageAnimationDiagnostics.event(
        "coordinator reject unusable-source random=\(source.identity.randomId) text=[\(SendMessageAnimationDiagnostics.rect(source.sourceTextFrameInWindow))] visibleText=[\(SendMessageAnimationDiagnostics.rect(source.sourceVisibleTextFrameInWindow))] baselineY=\(String(format: "%.1f", source.sourceTextFirstBaselineYInWindow)) lineHeight=\(String(format: "%.1f", source.sourceLineHeight)) textLen=\(source.text.count)"
      )
      return false
    }

    removePreview(for: source.identity)
    pendingByIdentity[source.identity] = .prepared(source)
    SendMessageAnimationDiagnostics.debug(
      "coordinator prepared mode=unified-geometry random=\(source.identity.randomId) temp=\(source.identity.temporaryMessageId) text=[\(SendMessageAnimationDiagnostics.rect(source.sourceTextFrameInWindow))] visibleText=[\(SendMessageAnimationDiagnostics.rect(source.sourceVisibleTextFrameInWindow))] baselineY=\(String(format: "%.1f", source.sourceTextFirstBaselineYInWindow)) visibleBottomY=\(String(format: "%.1f", source.sourceVisibleTextFrameInWindow.maxY)) lineHeight=\(String(format: "%.1f", source.sourceLineHeight)) textLen=\(source.text.count)"
    )
    schedulePreparedSourceCleanup(for: source.identity)
    return true
  }

  func cancel(identity: SendMessageAnimationIdentity) {
    removePreview(for: identity)
    cleanupTasksByIdentity.removeValue(forKey: identity)?.cancel()
    SendMessageAnimationDiagnostics.debug(
      "coordinator cancel random=\(identity.randomId) temp=\(identity.temporaryMessageId)"
    )
  }

  func cancelAll() {
    pendingByIdentity.values.forEach { state in
      revealTarget(for: state)
      preview(for: state)?.cancel()
    }
    pendingByIdentity.removeAll(keepingCapacity: true)
    identityByStableMessageId.removeAll(keepingCapacity: true)
    cleanupTasksByIdentity.values.forEach { $0.cancel() }
    cleanupTasksByIdentity.removeAll(keepingCapacity: true)
  }

  func pendingIdentity(for message: FullMessage) -> SendMessageAnimationIdentity? {
    if let identity = identityByStableMessageId[message.id],
       pendingByIdentity[identity] != nil {
      SendMessageAnimationDiagnostics.debug(
        "match stable stable=\(message.id) msgId=\(message.message.messageId) random=\(message.message.randomId.map(String.init) ?? "nil") identityRandom=\(identity.randomId)"
      )
      return identity
    }

    if let identity = pendingByIdentity.keys.first(where: { identity in
      message.message.randomId == identity.randomId ||
        message.message.messageId == identity.temporaryMessageId
    }) {
      identityByStableMessageId[message.id] = identity
      SendMessageAnimationDiagnostics.debug(
        "match direct stable=\(message.id) msgId=\(message.message.messageId) random=\(message.message.randomId.map(String.init) ?? "nil") identityRandom=\(identity.randomId)"
      )
      return identity
    }

    return nil
  }

  func hasPendingAnimation(for message: FullMessage) -> Bool {
    pendingIdentity(for: message) != nil
  }

  func isAnimating(identity: SendMessageAnimationIdentity) -> Bool {
    guard case .animating = pendingByIdentity[identity] else {
      return false
    }
    return true
  }

  func retargetDuration(for identity: SendMessageAnimationIdentity) -> TimeInterval? {
    guard let state = pendingByIdentity[identity] else { return nil }
    return SendMessageAnimationTiming.retargetDuration(preparedAt: source(for: state).preparedAt)
  }

  func activeAnimatingIdentitiesByStableMessageId(
    excluding excludedIdentities: Set<SendMessageAnimationIdentity> = []
  ) -> [Int64: SendMessageAnimationIdentity] {
    identityByStableMessageId.reduce(into: [:]) { result, element in
      let (stableMessageId, identity) = element
      guard !excludedIdentities.contains(identity),
            case .animating = pendingByIdentity[identity]
      else {
        return
      }
      result[stableMessageId] = identity
    }
  }

  func beginIfPossible(
    target: SendMessageAnimationTarget,
    revealTarget: @escaping (SendMessageAnimationTarget) -> Void
  ) -> Bool {
    guard let state = pendingByIdentity[target.identity],
          case let .prepared(source) = state,
          let hostView
    else {
      SendMessageAnimationDiagnostics.event(
        "begin unavailable random=\(target.identity.randomId) hasState=\(pendingByIdentity[target.identity] != nil) hasHost=\(hostView != nil)"
      )
      return false
    }

    let previewView = SendMessageAnimationPreviewView(source: source)
    identityByStableMessageId[target.messageStableId] = target.identity
    pendingByIdentity[target.identity] = .animating(
      source: source,
      preview: previewView,
      target: target,
      revealTarget: revealTarget
    )
    cleanupTasksByIdentity.removeValue(forKey: target.identity)?.cancel()
    let delayMs = Date().timeIntervalSince(source.preparedAt) * 1_000
    SendMessageAnimationDiagnostics.event(
      "begin preview random=\(target.identity.randomId) stable=\(target.messageStableId) delayMs=\(String(format: "%.1f", delayMs))"
    )
    SendMessageAnimationDiagnostics.debug(
      "begin preview mode=real-target-bubble random=\(target.identity.randomId) stable=\(target.messageStableId) delayMs=\(String(format: "%.1f", delayMs)) sourceText=[\(SendMessageAnimationDiagnostics.rect(source.sourceVisibleTextFrameInWindow))] sourceBaselineY=\(String(format: "%.1f", source.sourceTextFirstBaselineYInWindow)) sourceBottomY=\(String(format: "%.1f", source.sourceVisibleTextFrameInWindow.maxY)) sourceLineHeight=\(String(format: "%.1f", source.sourceLineHeight)) targetBubble=[\(SendMessageAnimationDiagnostics.rect(target.bubbleFrameInWindow))] targetText=[\(SendMessageAnimationDiagnostics.rect(target.textFrameInWindow))] targetTextInBubble=[\(SendMessageAnimationDiagnostics.rect(target.textFrameInBubble))] targetBaselineY=\(String(format: "%.1f", target.textFirstBaselineYInWindow)) tail=\(target.bubbleTailSide) targetSnapshot=\(type(of: target.bubbleSnapshotView))"
    )

    scheduleAnimatingCleanup(for: target.identity, stableId: target.messageStableId)
    previewView.animate(to: target, in: hostView) { [weak self] in
      self?.completeAnimation(identity: target.identity)
    }

    return true
  }

  @discardableResult
  func retargetIfPossible(
    target: SendMessageAnimationTarget,
    duration: TimeInterval,
    revealTarget: @escaping (SendMessageAnimationTarget) -> Void
  ) -> Bool {
    guard let state = pendingByIdentity[target.identity],
          case let .animating(source, preview, oldTarget, _) = state
    else {
      SendMessageAnimationDiagnostics.event(
        "retarget unavailable random=\(target.identity.randomId) stable=\(target.messageStableId) hasState=\(pendingByIdentity[target.identity] != nil)"
      )
      return false
    }

    let didRetarget = preview.retarget(to: target, duration: duration)
    if didRetarget {
      identityByStableMessageId[target.messageStableId] = target.identity
      pendingByIdentity[target.identity] = .animating(
        source: source,
        preview: preview,
        target: target,
        revealTarget: revealTarget
      )
      SendMessageAnimationDiagnostics.debug(
        "coordinator retarget random=\(target.identity.randomId) stable=\(target.messageStableId) oldBubble=[\(SendMessageAnimationDiagnostics.rect(oldTarget.bubbleFrameInWindow))] newBubble=[\(SendMessageAnimationDiagnostics.rect(target.bubbleFrameInWindow))] delta=[\(SendMessageAnimationGeometry.rectDelta(from: oldTarget.bubbleFrameInWindow, to: target.bubbleFrameInWindow))] duration=\(String(format: "%.3f", duration))"
      )
      scheduleAnimatingCleanup(for: target.identity, stableId: target.messageStableId)
    }
    return didRetarget
  }

  private func schedulePreparedSourceCleanup(for identity: SendMessageAnimationIdentity) {
    cleanupTasksByIdentity.removeValue(forKey: identity)?.cancel()
    cleanupTasksByIdentity[identity] = Task {
      do {
        try await Task.sleep(nanoseconds: 1_200_000_000)
      } catch {
        return
      }

      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self else { return }
        guard case .prepared = pendingByIdentity[identity] else { return }
        removePreview(for: identity)
        cleanupTasksByIdentity.removeValue(forKey: identity)
        SendMessageAnimationDiagnostics.debug(
          "cleanup expired random=\(identity.randomId) temp=\(identity.temporaryMessageId)"
        )
      }
    }
  }

  private func scheduleAnimatingCleanup(
    for identity: SendMessageAnimationIdentity,
    stableId: Int64
  ) {
    cleanupTasksByIdentity.removeValue(forKey: identity)?.cancel()
    cleanupTasksByIdentity[identity] = Task {
      let timeout = SendMessageAnimationTiming.duration + 0.6
      do {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      } catch {
        return
      }

      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self else { return }
        guard case .animating = pendingByIdentity[identity] else { return }
        removePreview(for: identity)
        cleanupTasksByIdentity.removeValue(forKey: identity)
        SendMessageAnimationDiagnostics.debug(
          "cleanup animating-timeout random=\(identity.randomId) temp=\(identity.temporaryMessageId) stable=\(stableId)"
        )
      }
    }
  }

  private func source(for state: PendingState) -> SendMessageAnimationSource {
    switch state {
    case let .prepared(source), let .animating(source, _, _, _):
      source
    }
  }

  private func preview(for state: PendingState) -> SendMessageAnimationPreviewView? {
    switch state {
    case .prepared:
      nil
    case let .animating(_, preview, _, _):
      preview
    }
  }

  private func revealTarget(for state: PendingState) {
    switch state {
    case .prepared:
      break
    case let .animating(_, _, target, revealTarget):
      revealTarget(target)
    }
  }

  private func completeAnimation(identity: SendMessageAnimationIdentity) {
    guard let state = pendingByIdentity.removeValue(forKey: identity) else { return }
    removeStableMessageIdMappings(for: identity)
    cleanupTasksByIdentity.removeValue(forKey: identity)?.cancel()

    guard case let .animating(_, _, target, revealTarget) = state else {
      return
    }

    revealTarget(target)
    SendMessageAnimationDiagnostics.event(
      "complete preview random=\(target.identity.randomId) stable=\(target.messageStableId)"
    )
  }

  private func removePreview(for identity: SendMessageAnimationIdentity) {
    guard let state = pendingByIdentity.removeValue(forKey: identity) else { return }
    removeStableMessageIdMappings(for: identity)
    revealTarget(for: state)
    preview(for: state)?.cancel()
  }

  private func removeStableMessageIdMappings(for identity: SendMessageAnimationIdentity) {
    identityByStableMessageId = identityByStableMessageId.filter { $0.value != identity }
  }
}
