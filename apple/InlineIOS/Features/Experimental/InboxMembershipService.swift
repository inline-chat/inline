import GRDB
import InlineKit
import InlineProtocol
import RealtimeV2

/// Canonical New Home membership mutations. Keeping Search, notifications, deep links,
/// and row actions on one path prevents hidden reply threads and pinned closed chats
/// from drifting into different local states.
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
    let outcome = try await reconciler.submit(peer: peer, intent: .open)
    return outcome.didConvergeRequestedIntent && outcome.didMutate
  }

  @discardableResult
  func close(peer: InlineKit.Peer) async throws -> Bool {
    let outcome = try await reconciler.submit(peer: peer, intent: .close)
    return outcome.didConvergeRequestedIntent && outcome.didMutate
  }

  @discardableResult
  func setPinned(peer: InlineKit.Peer, pinned: Bool) async throws -> Bool {
    let outcome = try await reconciler.submit(peer: peer, intent: .setPinned(pinned))
    return outcome.didConvergeRequestedIntent && outcome.didMutate
  }
}
