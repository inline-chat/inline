import Foundation

enum DialogMutationKind: Hashable, Sendable {
  case open
  case order
  case read
}

struct DialogMutationRollbackEntry: Sendable {
  let original: Dialog?
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

  private var pendingByKey: [Key: Pending] = [:]

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
}
