import Foundation
import InlineProtocol

/// Composes ordinary chat operations. The draft owns the immutable submission;
/// each RPC retains its own existing transport owner and replay contract.
public struct DiscussionCarryOverSubmission: Sendable {
  public enum Outcome: Equatable, Sendable {
    case created(Peer)
    case openedExisting(Peer)
  }

  /// A reservation is not proof that Create committed, nor that access remains.
  /// Navigation uses a current authorized snapshot of that exact destination.
  public static func openExistingChat(
    peer: Peer,
    fetch: @Sendable (Peer) async throws -> RpcResult.OneOf_Result?,
    validateAccount: @Sendable () throws -> Void
  ) async throws -> Outcome {
    try validateAccount()
    let result = try await fetch(peer)
    try validateAccount()
    guard case let .getChat(response) = result, response.hasChat,
          response.chat.peerID.type != nil, response.chat.peerID.toPeer() == peer,
          Chat(from: response.chat).deepLinkPeer == peer else {
      throw DiscussionCarryOverNavigationError.unconfirmedDestination
    }
    return .openedExisting(peer)
  }

  public let persist: @Sendable (DiscussionCarryOverDraft) async throws -> Void
  public let admit: @Sendable (DiscussionCarryOverDraft) async throws -> Void
  public let create: @Sendable (DiscussionCarryOverDraft) async throws -> Int64
  public let forward: @Sendable (DiscussionCarryOverDraft) async throws -> Void
  public let addParticipant: @Sendable (Int64, Int64) async throws -> Void
  public let activate: @Sendable (DiscussionCarryOverDraft) async throws -> Void

  public init(
    persist: @escaping @Sendable (DiscussionCarryOverDraft) async throws -> Void,
    admit: @escaping @Sendable (DiscussionCarryOverDraft) async throws -> Void,
    create: @escaping @Sendable (DiscussionCarryOverDraft) async throws -> Int64,
    forward: @escaping @Sendable (DiscussionCarryOverDraft) async throws -> Void,
    addParticipant: @escaping @Sendable (Int64, Int64) async throws -> Void,
    activate: @escaping @Sendable (DiscussionCarryOverDraft) async throws -> Void
  ) {
    self.persist = persist
    self.admit = admit
    self.create = create
    self.forward = forward
    self.addParticipant = addParticipant
    self.activate = activate
  }

  public func submit(_ draft: DiscussionCarryOverDraft) async throws -> Outcome {
    guard draft.hasValidIdentity else { throw DiscussionCarryOverPersistenceError.invalidIntent }
    // A lost create result must return to this exact reservation on the next try.
    try await persist(draft)
    try await admit(draft)
    let destinationId = try await create(draft)
    try await admit(draft)
    let peer = Peer.thread(id: destinationId)
    guard destinationId == draft.reservedChatId else {
      // One anchor has one child. Reusing it is navigation only.
      return .openedExisting(peer)
    }
    // Reconcile the exact receipt identities on every attempt, including a
    // completed seed that may have been deleted before an activation retry.
    try await forward(draft)
    try await admit(draft)
    var seeded = draft
    if !draft.seedComplete {
      seeded.seedComplete = true
      try await persist(seeded)
    }
    if let botUserId = draft.botUserId {
      try await admit(seeded)
      try await addParticipant(destinationId, botUserId)
    }
    if !draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try await admit(seeded)
      try await activate(seeded)
    }
    try await admit(seeded)
    return .created(peer)
  }
}

private enum DiscussionCarryOverNavigationError: LocalizedError {
  case unconfirmedDestination
  var errorDescription: String? {
    "The saved chat is not available. Retry creating it, or review the updated context to start a new chat."
  }
}
