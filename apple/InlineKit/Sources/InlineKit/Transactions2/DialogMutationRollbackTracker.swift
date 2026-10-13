import Foundation
import GRDB
import InlineProtocol

enum DialogMutationKind: Hashable, Sendable {
  case open
  case order
  case read
}

/// Dialog columns an optimistic dialog mutation can own.
enum DialogRollbackField: Hashable, Sendable {
  case open
  case openedDate
  case order
  case pinnedOrder
  case folderId
  case pinned
  case archived
  case chatListHidden
  case unreadMark
  case unreadCount

  func isEqual(_ lhs: Dialog, _ rhs: Dialog) -> Bool {
    switch self {
    case .open: lhs.open == rhs.open
    case .openedDate: lhs.openedDate == rhs.openedDate
    case .order: lhs.order == rhs.order
    case .pinnedOrder: lhs.pinnedOrder == rhs.pinnedOrder
    case .folderId: lhs.folderId == rhs.folderId
    case .pinned: lhs.pinned == rhs.pinned
    case .archived: lhs.archived == rhs.archived
    case .chatListHidden: lhs.chatListHidden == rhs.chatListHidden
    case .unreadMark: lhs.unreadMark == rhs.unreadMark
    case .unreadCount: lhs.unreadCount == rhs.unreadCount
    }
  }

  func copy(from source: Dialog, to target: inout Dialog) {
    switch self {
    case .open: target.open = source.open
    case .openedDate: target.openedDate = source.openedDate
    case .order: target.order = source.order
    case .pinnedOrder: target.pinnedOrder = source.pinnedOrder
    case .folderId: target.folderId = source.folderId
    case .pinned: target.pinned = source.pinned
    case .archived: target.archived = source.archived
    case .chatListHidden: target.chatListHidden = source.chatListHidden
    case .unreadMark: target.unreadMark = source.unreadMark
    case .unreadCount: target.unreadCount = source.unreadCount
    }
  }
}

/// The dialog row immediately before and after one optimistic write.
struct DialogMutationSnapshot: Sendable {
  let baseline: Dialog
  /// Read back from the database so later comparisons see stored precision.
  let optimistic: Dialog
  /// True when the optimistic write inserted the row.
  let createdRow: Bool
}

enum DialogMutationRollbackResolution: Equatable, Sendable {
  case unchanged
  case save(Dialog)
  case delete
}

struct DialogMutationRollbackEntry: Sendable {
  let baseline: Dialog
  let optimistic: Dialog
  /// Fields no later pending intent has taken over.
  let fields: [DialogRollbackField]
  let deletesUntouchedRow: Bool

  /// Reverts only what this intent still owns: a field that no longer holds
  /// the optimistic value was written by the server or another intent.
  func resolve(current: Dialog) -> DialogMutationRollbackResolution {
    if deletesUntouchedRow {
      // Sidebar cleanup refreshes openedDate on its own schedule.
      var comparable = current
      comparable.openedDate = optimistic.openedDate
      if comparable == optimistic { return .delete }
    }

    var restored = current
    for field in fields where field.isEqual(current, optimistic) {
      field.copy(from: baseline, to: &restored)
    }
    return restored == current ? .unchanged : .save(restored)
  }

  func apply(_ db: Database) throws {
    guard let current = try Dialog.fetchOne(db, id: optimistic.id) else { return }
    switch resolve(current: current) {
    case .unchanged:
      return
    case let .save(dialog):
      try dialog.save(db, onConflict: .replace)
    case .delete:
      try Dialog.deleteOne(db, id: current.id)
    }
  }
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
    let kind: DialogMutationKind
    var baseline: Dialog
    let optimistic: Dialog
    let fields: [DialogRollbackField]
    var createdRow: Bool
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

  /// Pending intents per peer, oldest first. Kinds share one chain because
  /// open and order mutations write overlapping columns.
  private var pendingByPeer: [Peer: [Pending]] = [:]
  private var notificationChainsByPeer: [Peer: NotificationChain] = [:]
  private var notificationReservationCountsByPeer: [Peer: [String: Int]] = [:]
  private var nextNotificationResolutionToken: UInt64 = 0

  func record(
    intentID: String?,
    peer: Peer,
    kind: DialogMutationKind,
    snapshot: DialogMutationSnapshot,
    fields: [DialogRollbackField]
  ) {
    guard let intentID else { return }
    pendingByPeer[peer, default: []].append(Pending(
      intentID: intentID,
      kind: kind,
      baseline: snapshot.baseline,
      optimistic: snapshot.optimistic,
      fields: fields,
      createdRow: snapshot.createdRow
    ))
  }

  func complete(intentID: String?, peer: Peer, kind: DialogMutationKind) {
    guard let intentID, var chain = pendingByPeer[peer],
          let index = chain.firstIndex(where: { $0.intentID == intentID && $0.kind == kind })
    else { return }
    chain.remove(at: index)
    pendingByPeer[peer] = chain.isEmpty ? nil : chain
  }

  func takeForRollback(intentID: String?, peer: Peer, kind: DialogMutationKind) -> DialogMutationRollbackEntry? {
    guard let intentID, var chain = pendingByPeer[peer],
          let index = chain.firstIndex(where: { $0.intentID == intentID && $0.kind == kind })
    else { return nil }

    let failed = chain.remove(at: index)
    let hasLaterIntent = index < chain.count
    if failed.createdRow, hasLaterIntent {
      // A later intent that started from the untouched inserted row inherits
      // responsibility for removing it.
      var laterBaseline = chain[index].baseline
      laterBaseline.openedDate = failed.optimistic.openedDate
      if laterBaseline == failed.optimistic {
        chain[index].createdRow = true
      }
    }

    var fields: [DialogRollbackField] = []
    for field in failed.fields {
      // A later intent that writes the same field now owns its value. Hand it
      // this intent's baseline so its own failure restores the true original.
      guard let later = chain[index...].firstIndex(where: { $0.fields.contains(field) }) else {
        fields.append(field)
        continue
      }
      if field.isEqual(chain[later].baseline, failed.optimistic) {
        field.copy(from: failed.baseline, to: &chain[later].baseline)
      }
    }

    pendingByPeer[peer] = chain.isEmpty ? nil : chain
    return DialogMutationRollbackEntry(
      baseline: failed.baseline,
      optimistic: failed.optimistic,
      fields: fields,
      deletesUntouchedRow: failed.createdRow && !hasLaterIntent
    )
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
