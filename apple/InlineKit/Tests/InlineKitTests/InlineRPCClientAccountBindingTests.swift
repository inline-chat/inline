import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import Auth
@testable import InlineKit

/// A response that completes just before logout or an account switch must not be projected, or
/// saved, under the account that is current when the wrapper resumes.
@Suite("InlineRPCClient account binding", .serialized)
struct InlineRPCClientAccountBindingTests {
  enum Wrapper: String, CaseIterable, Sendable {
    case setProfilePhoto, deleteMessage, addReaction, updateDialogArchived, deleteMessageAttachment

    var response: InlineProtocol.RpcResult.OneOf_Result {
      let updates = [InlineProtocol.Update()]
      return switch self {
      case .setProfilePhoto: .setProfilePhoto(.with {
          $0.updates = updates
          $0.user = .with { $0.id = 42 }
        })
      case .deleteMessage: .deleteMessages(.with { $0.updates = updates })
      case .addReaction: .addReaction(.with { $0.updates = updates })
      case .updateDialogArchived: .updateDialogArchived(.with { $0.updates = updates })
      case .deleteMessageAttachment: .deleteMessageAttachment(.with { $0.updates = updates })
      }
    }

    func invoke(_ client: InlineRPCClient, accountToken: AuthAccountMutationToken) async throws {
      let peer = Peer.thread(id: 77)
      switch self {
      case .setProfilePhoto:
        _ = try await client.setProfilePhoto(fileUniqueID: "photo", accountToken: accountToken)
      case .deleteMessage:
        try await client.deleteMessage(peerID: peer, messageID: 9, accountToken: accountToken)
      case .addReaction:
        try await client.addReaction(peerID: peer, messageID: 9, emoji: "👍", accountToken: accountToken)
      case .updateDialogArchived:
        try await client.updateDialogArchived(peerID: peer, archived: true, accountToken: accountToken)
      case .deleteMessageAttachment:
        try await client.deleteMessageAttachment(
          peerID: peer, messageID: 9, attachmentID: 3, accountToken: accountToken
        )
      }
    }
  }

  enum AccountChange: String, CaseIterable, Sendable {
    /// A logs out and B signs in.
    case otherAccount
    /// A logs out and signs back in: same user, new account generation.
    case sameAccountAfterLogout
  }

  @Test("a held response is not projected after the account changes", arguments: Wrapper.allCases, AccountChange.allCases)
  func heldResponseIsRejected(wrapper: Wrapper, change: AccountChange) async throws {
    let accounts = Accounts(userID: 42)
    let realtime = HeldRealtime(auth: accounts.auth, response: wrapper.response)
    let client = InlineRPCClient { realtime }
    let tokenA = try accounts.auth.beginAccountMutation()

    let call = Task { try await wrapper.invoke(client, accountToken: tokenA) }
    await realtime.waitUntilHeld()
    try accounts.apply(change)
    await realtime.release()

    await #expect(throws: AuthStorageError.self) { try await call.value }
    #expect(await realtime.appliedBatches == 0)
  }

  @Test("an unchanged account projects the response with the token it started with", arguments: Wrapper.allCases)
  func unchangedAccountProjects(wrapper: Wrapper) async throws {
    let accounts = Accounts(userID: 42)
    let realtime = HeldRealtime(auth: accounts.auth, response: wrapper.response)
    let client = InlineRPCClient { realtime }
    let token = try accounts.auth.beginAccountMutation()

    let call = Task { try await wrapper.invoke(client, accountToken: token) }
    await realtime.waitUntilHeld()
    await realtime.release()

    try await call.value
    #expect(await realtime.appliedBatches == 1)
    #expect(await realtime.requestTokens == [token])
  }

  @Test("a request bound to a replaced account is never sent")
  func staleTokenIsRejectedAtAdmission() async throws {
    let accounts = Accounts(userID: 42)
    let realtime = HeldRealtime(auth: accounts.auth, response: Wrapper.addReaction.response)
    let client = InlineRPCClient { realtime }
    let tokenA = try accounts.auth.beginAccountMutation()
    try accounts.apply(.otherAccount)

    await #expect(throws: AuthStorageError.self) {
      try await Wrapper.addReaction.invoke(client, accountToken: tokenA)
    }
    #expect(await realtime.requestTokens.isEmpty)
  }

  /// `.projection` holds after the updates were applied, so only the caller's own save check
  /// stands between the stale user and the next account's database.
  @Test(
    "profile photo result is not saved into the next account's database",
    arguments: AccountChange.allCases, [HeldRealtime.HoldPoint.response, .projection]
  )
  @MainActor
  func profilePhotoResultIsNotSaved(change: AccountChange, holdPoint: HeldRealtime.HoldPoint) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let accounts = Accounts(userID: 42)
    let realtime = HeldRealtime(auth: accounts.auth, response: Wrapper.setProfilePhoto.response, holdPoint: holdPoint)
    let data = DataManager(database: database, auth: accounts.auth, rpc: InlineRPCClient { realtime })
    let tokenA = try accounts.auth.beginAccountMutation()

    let call = Task { @MainActor in try await data.setProfilePhoto(fileUniqueID: "photo", accountToken: tokenA) }
    await realtime.waitUntilHeld()
    try accounts.apply(change)
    await realtime.release()

    await #expect(throws: AuthStorageError.self) { try await call.value }
    #expect(try await queue.read { db in try User.fetchCount(db) } == 0)
  }

  @Test("profile photo result is saved for an unchanged account")
  @MainActor
  func profilePhotoResultIsSaved() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let accounts = Accounts(userID: 42)
    let realtime = HeldRealtime(auth: accounts.auth, response: Wrapper.setProfilePhoto.response)
    let data = DataManager(database: database, auth: accounts.auth, rpc: InlineRPCClient { realtime })
    let token = try accounts.auth.beginAccountMutation()

    let call = Task { @MainActor in try await data.setProfilePhoto(fileUniqueID: "photo", accountToken: token) }
    await realtime.waitUntilHeld()
    await realtime.release()

    try await call.value
    #expect(try await queue.read { db in try User.fetchOne(db, id: 42) } != nil)
  }
}

/// Synchronous account transitions on a real snapshot cache, so a switch lands exactly while the
/// response is held.
private final class Accounts: Sendable {
  let cache: AuthSnapshotCache
  let auth: AuthHandle
  private let userID: Int64

  init(userID: Int64) {
    self.userID = userID
    let initial = AuthSnapshot(
      status: .authenticated(AuthCredentials(userId: userID, token: "\(userID):token")),
      didHydrate: true
    )
    cache = AuthSnapshotCache(initial: initial)
    let store = AuthStore(
      cache: cache,
      mocked: true,
      namespace: UUID().uuidString,
      readSnapshot: { @Sendable _, _, _ in initial }
    )
    auth = AuthHandle(cache: cache, store: store)
  }

  func apply(_ change: InlineRPCClientAccountBindingTests.AccountChange) throws {
    let logout = cache.beginLogout()
    #expect(cache.completeLogout(
      logout,
      snapshot: AuthSnapshot(status: .unauthenticated, didHydrate: true),
      publish: {}
    ))
    switch change {
    case .otherAccount: try signIn(userID: 7)
    case .sameAccountAfterLogout: try signIn(userID: userID)
    }
  }

  private func signIn(userID: Int64) throws {
    let attempt = cache.makeLoginAttempt()
    #expect(cache.beginAuthorityStaging(attempt))
    let snapshot = AuthSnapshot(
      status: .authenticated(AuthCredentials(userId: userID, token: "\(userID):next")),
      didHydrate: true
    )
    #expect(cache.finishAuthorityStaging(snapshot, owner: attempt))
    #expect(cache.prepareStagedAuthorityFinalization(attempt))
    _ = try #require(cache.finalizeStagedAuthority(attempt, publish: { _ in }))
  }
}

/// Mirrors RealtimeV2's account checks: admission validates the request token and
/// `applyUpdatesAndWait(_:accountToken:)` validates the projection token. The response is held
/// after it completes, before the wrapper resumes.
actor HeldRealtime: InlineRPCRealtime {
  enum HoldPoint: Sendable {
    /// The response completed; the wrapper has not resumed.
    case response
    /// The wrapper projected the updates; its caller has not saved the result.
    case projection
  }

  private let auth: AuthHandle
  private let response: InlineProtocol.RpcResult.OneOf_Result
  private let holdPoint: HoldPoint
  private var isHeld = false
  private var heldWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var requestTokens: [AuthAccountMutationToken] = []
  private(set) var appliedBatches = 0

  init(auth: AuthHandle, response: InlineProtocol.RpcResult.OneOf_Result, holdPoint: HoldPoint = .response) {
    self.auth = auth
    self.response = response
    self.holdPoint = holdPoint
  }

  func callRpcDirect(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?,
    accountToken: AuthAccountMutationToken?
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    if let accountToken {
      try auth.validateAccountMutation(accountToken)
      requestTokens.append(accountToken)
    }
    if holdPoint == .response { await hold() }
    return response
  }

  func applyUpdatesAndWait(
    _ updates: [InlineProtocol.Update], accountToken: AuthAccountMutationToken
  ) async throws {
    try auth.validateAccountMutation(accountToken)
    appliedBatches += 1
    if holdPoint == .projection { await hold() }
  }

  private func hold() async {
    isHeld = true
    heldWaiters.forEach { $0.resume() }
    heldWaiters = []
    if !released {
      await withCheckedContinuation { releaseContinuation = $0 }
    }
  }

  func waitUntilHeld() async {
    guard !isHeld else { return }
    await withCheckedContinuation { heldWaiters.append($0) }
  }

  func release() {
    released = true
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
