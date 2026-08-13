import GRDB
import InlineKit
import InlineProtocol
import RealtimeV2

/// Canonical New Home membership mutations. Search, notifications, deep links,
/// and row actions share the same per-peer latest-intent reconciler.
actor InboxMembershipService {
  static let shared = InboxMembershipService()

  private let reconciler = InboxMembershipReconciler(
    loadState: { peer in
      try await AppDatabase.shared.reader.read { db in
        let dialog = try Dialog.get(peerId: peer).fetchOne(db)
        let chat: InlineKit.Chat? = switch peer {
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
        _ = try await Api.realtime.send(.updateDialogOpen(peerId: peer, open: isOpen))
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
  func open(peer: InlineKit.Peer) async throws -> Bool {
    if case let .converged(didMutate) = try await reconciler.submit(peer: peer, intent: .open) {
      return didMutate
    }
    return false
  }

  @discardableResult
  func close(peer: InlineKit.Peer) async throws -> Bool {
    if case let .converged(didMutate) = try await reconciler.submit(peer: peer, intent: .close) {
      return didMutate
    }
    return false
  }
}
