import GRDB
import InlineKit
import InlineProtocol
import RealtimeV2

/// Canonical New Home membership mutations. Keeping Search, notifications, deep links,
/// and row actions on one path prevents hidden reply threads and pinned closed chats
/// from drifting into different local states.
actor InboxMembershipService {
  static let shared = InboxMembershipService()

  private var pendingPeers = Set<InlineKit.Peer>()

  @discardableResult
  func open(peer: InlineKit.Peer) async throws -> Bool {
    guard pendingPeers.insert(peer).inserted else { return false }
    defer { pendingPeers.remove(peer) }

    let state = try await AppDatabase.shared.reader.read { db in
      try InboxMembershipState(peer: peer, db: db)
    }
    var didMutate = false

    if state.followMode == .unfollowed {
      _ = try await Api.realtime.send(
        .updateDialogFollowMode(peerId: peer, selection: .following)
      )
      didMutate = true
    }

    if state.isChatListHidden || state.needsReplyThreadReveal {
      _ = try await Api.realtime.send(.showInChatList(peerId: peer))
      didMutate = true
    }

    if !state.isOpen {
      _ = try await Api.realtime.send(.updateDialogOpen(peerId: peer, open: true))
      didMutate = true
    }

    if state.isArchived {
      try await DataManager.shared.updateDialog(
        peerId: peer,
        archived: false,
        deleteEmptyThreadIfArchiving: false
      )
      didMutate = true
    }

    return didMutate
  }

  @discardableResult
  func close(peer: InlineKit.Peer) async throws -> Bool {
    guard pendingPeers.insert(peer).inserted else { return false }
    defer { pendingPeers.remove(peer) }

    let state = try await AppDatabase.shared.reader.read { db in
      try InboxMembershipState(peer: peer, db: db)
    }
    var didMutate = false

    if state.isOpen {
      _ = try await Api.realtime.send(.updateDialogOpen(peerId: peer, open: false))
      didMutate = true
    }

    if state.isPinned {
      _ = try await Api.realtime.send(.updateDialogOrder(peerId: peer, pinned: false))
      didMutate = true
    }

    return didMutate
  }
}

private struct InboxMembershipState: Sendable {
  let isOpen: Bool
  let isPinned: Bool
  let isArchived: Bool
  let isChatListHidden: Bool
  let followMode: InlineProtocol.DialogFollowMode?
  let needsReplyThreadReveal: Bool

  init(peer: InlineKit.Peer, db: Database) throws {
    let dialog = try Dialog.get(peerId: peer).fetchOne(db)
    let chat: InlineKit.Chat? = switch peer {
    case .user:
      nil
    case let .thread(id):
      try Chat.fetchOne(db, id: id)
    }

    isOpen = dialog?.open == true
    isPinned = dialog?.pinned == true
    isArchived = dialog?.archived == true
    isChatListHidden = dialog?.chatListHidden == true
    followMode = dialog?.followMode
    needsReplyThreadReveal = dialog == nil && chat?.isReplyThread == true
  }
}
