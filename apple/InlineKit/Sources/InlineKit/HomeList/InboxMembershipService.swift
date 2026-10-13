import GRDB
import InlineProtocol
import RealtimeV2

/// Canonical Inbox membership mutations. Sends, search, notifications, deep
/// links, and row actions share the same per-peer latest-intent reconciler, so
/// a chat that is already in the desired state costs one local read.
public actor InboxMembershipService {
  public static let shared = InboxMembershipService()

  private let reconciler = InboxMembershipReconciler(
    loadState: { peer in
      try await AppDatabase.shared.reader.read { db in
        let dialog = try Dialog.get(peerId: peer).fetchOne(db)
        let chat: Chat? = switch peer {
        case .user:
          nil
        case let .thread(id):
          try Chat.fetchOne(db, id: id)
        }

        return InboxMembershipCanonicalState(
          isOpen: dialog?.open == true,
          isPinned: dialog?.pinned == true,
          isArchived: dialog?.archived == true,
          isChatListHidden: dialog?.chatListHidden == true,
          isUnfollowed: dialog?.followMode == .unfollowed,
          needsReplyThreadReveal: dialog == nil && chat?.isReplyThread == true
        )
      }
    },
    performMutation: { peer, mutation in
      switch mutation {
      case .follow:
        _ = try await Api.realtime.send(
          .updateDialogFollowMode(peerId: peer, selection: .following)
        )
      case .showInChatList:
        _ = try await Api.realtime.send(.showInChatList(peerId: peer))
      case let .setOpen(isOpen):
        // A thread still being created locally has no server chat yet; the
        // open must wait behind its creation instead of racing it.
        let awaitsCreation = isOpen ? try await InboxMembershipService.isAwaitingCreation(peer) : false
        _ = try await Api.realtime.send(
          .updateDialogOpen(peerId: peer, open: isOpen, requiresChatCreated: awaitsCreation)
        )
      case let .setPinned(isPinned):
        _ = try await Api.realtime.send(.updateDialogOrder(peerId: peer, pinned: isPinned))
      case let .setArchived(isArchived):
        try await DataManager.shared.updateDialog(
          peerId: peer,
          archived: isArchived,
          deleteEmptyThreadIfArchiving: false
        )
      }
    }
  )

  @discardableResult
  public func open(peer: Peer) async throws -> Bool {
    try await submit(peer: peer, intent: .open)
  }

  @discardableResult
  public func close(peer: Peer) async throws -> Bool {
    try await submit(peer: peer, intent: .close)
  }

  /// Keeps a chat the user just acted in as an Inbox member.
  @discardableResult
  public func keep(peer: Peer) async throws -> Bool {
    try await submit(peer: peer, intent: .keep)
  }

  private func submit(peer: Peer, intent: InboxMembershipIntent) async throws -> Bool {
    if case let .converged(didMutate) = try await reconciler.submit(peer: peer, intent: intent) {
      return didMutate
    }
    return false
  }

  private static func isAwaitingCreation(_ peer: Peer) async throws -> Bool {
    guard case let .thread(chatId) = peer else { return false }
    return try await AppDatabase.shared.reader.read { db in
      try Chat.fetchOne(db, id: chatId)?.createState != nil
    }
  }
}
