import Foundation
import InlineProtocol

enum DialogMutationKind: Hashable, Sendable {
  case open
  case order
  case read
}

struct DialogMutationRollbackEntry: Sendable {
  let original: Dialog?
}

struct DialogNotificationMutationResolution: Sendable {
  let token: UInt64
  let expectedCurrentSelection: DialogNotificationSettingSelection
  let targetSelection: DialogNotificationSettingSelection
  let targetSettings: DialogNotificationSettings?
}

actor DialogMutationRollbackTracker {
  static let shared = DialogMutationRollbackTracker()

  private struct Pending: Sendable {
    let intentID: String
    let original: Dialog?
  }

  private struct Key: Hashable, Sendable {
    let peer: Peer
    let kind: DialogMutationKind
  }

  private enum NotificationIntentOutcome: Sendable, Equatable {
    case succeeded
    case failed
  }

  private enum NotificationIntentState: Sendable {
    case pending
    case resolving(NotificationIntentOutcome, token: UInt64)
    case finalized(NotificationIntentOutcome)

    var contributesValue: Bool {
      switch self {
      case .pending, .resolving(.succeeded, _), .finalized(.succeeded):
        true
      case .resolving(.failed, _), .finalized(.failed):
        false
      }
    }
  }

  private struct NotificationValue: Sendable {
    let selection: DialogNotificationSettingSelection
    let settings: DialogNotificationSettings?
  }

  private struct NotificationIntent: Sendable {
    let id: String
    let value: NotificationValue
    var state: NotificationIntentState
  }

  private struct NotificationChain: Sendable {
    var baseline: NotificationValue
    var intents: [NotificationIntent]
  }

  private var pendingByKey: [Key: Pending] = [:]
  private var notificationChainsByPeer: [Peer: NotificationChain] = [:]
  private var notificationReservationCountsByPeer: [Peer: [String: Int]] = [:]
  private var nextNotificationResolutionToken: UInt64 = 0

  func record(intentID: String?, peer: Peer, kind: DialogMutationKind, original: Dialog?) {
    guard let intentID else { return }
    pendingByKey[Key(peer: peer, kind: kind)] = Pending(intentID: intentID, original: original)
  }

  func complete(intentID: String?, peer: Peer, kind: DialogMutationKind) {
    let key = Key(peer: peer, kind: kind)
    guard let intentID, pendingByKey[key]?.intentID == intentID else { return }
    pendingByKey[key] = nil
  }

  func takeForRollback(intentID: String?, peer: Peer, kind: DialogMutationKind) -> DialogMutationRollbackEntry? {
    let key = Key(peer: peer, kind: kind)
    guard let intentID, let pending = pendingByKey[key], pending.intentID == intentID else {
      return nil
    }
    pendingByKey[key] = nil
    return DialogMutationRollbackEntry(original: pending.original)
  }

  func recordNotification(
    intentID: String?,
    peer: Peer,
    original: Dialog?,
    selection: DialogNotificationSettingSelection
  ) {
    guard let intentID else { return }
    defer { consumeNotificationReservation(intentID: intentID, peer: peer) }
    guard let original else { return }
    guard notificationChainsByPeer[peer]?.intents.contains(where: { $0.id == intentID }) != true else {
      return
    }

    let intent = NotificationIntent(
      id: intentID,
      value: NotificationValue(selection: selection, settings: selection.protocolSettings),
      state: .pending
    )

    if var chain = notificationChainsByPeer[peer] {
      chain.intents.append(intent)
      notificationChainsByPeer[peer] = chain
    } else {
      notificationChainsByPeer[peer] = NotificationChain(
        baseline: NotificationValue(
          selection: original.notificationSelection,
          settings: original.notificationSettings
        ),
        intents: [intent]
      )
    }
  }

  func reserveNotificationRecord(intentID: String?, peer: Peer) {
    guard let intentID else { return }
    var reservations = notificationReservationCountsByPeer[peer] ?? [:]
    reservations[intentID, default: 0] += 1
    notificationReservationCountsByPeer[peer] = reservations
  }

  func cancelNotificationRecordReservation(intentID: String?, peer: Peer) {
    guard let intentID else { return }
    consumeNotificationReservation(intentID: intentID, peer: peer)
  }

  func beginNotificationSuccess(
    intentID: String?,
    peer: Peer
  ) -> DialogNotificationMutationResolution? {
    beginNotificationResolution(intentID: intentID, peer: peer, outcome: .succeeded)
  }

  func beginNotificationFailure(
    intentID: String?,
    peer: Peer
  ) -> DialogNotificationMutationResolution? {
    beginNotificationResolution(intentID: intentID, peer: peer, outcome: .failed)
  }

  func abandonNotificationIntent(intentID: String?, peer: Peer) {
    guard let intentID, var chain = notificationChainsByPeer[peer] else { return }
    chain.intents.removeAll(where: { $0.id == intentID })
    if chain.intents.isEmpty, !hasNotificationRecordReservation(peer: peer) {
      notificationChainsByPeer[peer] = nil
    } else {
      notificationChainsByPeer[peer] = chain
    }
  }

  func finalizeNotificationResolution(token: UInt64, peer: Peer) {
    guard var chain = notificationChainsByPeer[peer],
          let index = chain.intents.firstIndex(where: { intent in
            guard case let .resolving(_, currentToken) = intent.state else { return false }
            return currentToken == token
          }),
          case let .resolving(outcome, _) = chain.intents[index].state
    else { return }

    chain.intents[index].state = .finalized(outcome)
    while let first = chain.intents.first {
      guard case let .finalized(finalizedOutcome) = first.state else { break }
      if finalizedOutcome == .succeeded {
        chain.baseline = first.value
      }
      chain.intents.removeFirst()
    }

    if chain.intents.isEmpty, !hasNotificationRecordReservation(peer: peer) {
      notificationChainsByPeer[peer] = nil
    } else {
      notificationChainsByPeer[peer] = chain
    }
  }

  private func beginNotificationResolution(
    intentID: String?,
    peer: Peer,
    outcome: NotificationIntentOutcome
  ) -> DialogNotificationMutationResolution? {
    guard let intentID,
          var chain = notificationChainsByPeer[peer],
          let index = chain.intents.firstIndex(where: { intent in
            guard case .pending = intent.state else { return false }
            return intent.id == intentID
          })
    else { return nil }

    let expectedCurrent = outcome == .succeeded
      ? chain.intents[index].value
      : effectiveNotificationValue(in: chain)
    nextNotificationResolutionToken &+= 1
    let token = nextNotificationResolutionToken
    chain.intents[index].state = .resolving(outcome, token: token)
    let target = effectiveNotificationValue(in: chain)
    notificationChainsByPeer[peer] = chain

    return DialogNotificationMutationResolution(
      token: token,
      expectedCurrentSelection: expectedCurrent.selection,
      targetSelection: target.selection,
      targetSettings: target.settings
    )
  }

  private func effectiveNotificationValue(in chain: NotificationChain) -> NotificationValue {
    chain.intents.last(where: { $0.state.contributesValue })?.value ?? chain.baseline
  }

  private func consumeNotificationReservation(intentID: String, peer: Peer) {
    guard var reservations = notificationReservationCountsByPeer[peer],
          let count = reservations[intentID]
    else { return }

    if count > 1 {
      reservations[intentID] = count - 1
      notificationReservationCountsByPeer[peer] = reservations
      return
    }

    reservations[intentID] = nil
    notificationReservationCountsByPeer[peer] = reservations.isEmpty ? nil : reservations
    if notificationChainsByPeer[peer]?.intents.isEmpty == true,
       !hasNotificationRecordReservation(peer: peer) {
      notificationChainsByPeer[peer] = nil
    }
  }

  private func hasNotificationRecordReservation(peer: Peer) -> Bool {
    notificationReservationCountsByPeer[peer]?.isEmpty == false
  }
}
