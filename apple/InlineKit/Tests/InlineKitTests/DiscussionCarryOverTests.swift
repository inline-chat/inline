@_spi(LogoutCoordinator) import Auth
import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Discussion carry-over")
struct DiscussionCarryOverTests {
  @Test("navigation requires the exact authorized destination, not a reservation alone", arguments: [false, true])
  func navigationRequiresDestination(exists: Bool) async throws {
    let expected = Peer.thread(id: 20)
    if exists {
      let outcome = try await DiscussionCarryOverSubmission.openExistingChat(peer: expected, fetch: { peer in
        #expect(peer == expected)
        return .getChat(.with { $0.chat.id = 20; $0.chat.peerID.chat.chatID = 20 })
      }, validateAccount: {})
      #expect(outcome == .openedExisting(expected))
    } else {
      await #expect(throws: (any Error).self) {
        try await DiscussionCarryOverSubmission.openExistingChat(peer: expected, fetch: { _ in
          .getChat(.with { $0.chat.id = 99; $0.chat.peerID.chat.chatID = 99 })
        }, validateAccount: {})
      }
    }
  }

  @Test("an authorized saved-chat read cannot navigate after an account transition")
  func navigationAccountChangesDuringRead() async throws {
    let auth = Auth.mocked(authenticated: false)
    try await auth.saveCredentials(token: "1:navigation-test-only", userId: 1)
    let token = try auth.handle.beginAccountMutation()
    await #expect(throws: (any Error).self) {
      try await DiscussionCarryOverSubmission.openExistingChat(peer: .thread(id: 20), fetch: { _ in
        try await auth.saveCredentials(token: "2:changed-test-only", userId: 2)
        return .getChat(.with { $0.chat.id = 20; $0.chat.peerID.chat.chatID = 20 })
      }, validateAccount: { try auth.handle.validateAccountMutation(token) })
    }
  }

  private func intent() -> DiscussionCarryOverDraft {
    let messages = [Int64(3), 5].map { id in
      var full = FullMessage(senderInfo: UserInfo(user: User(id: 1, email: nil, firstName: "Human")),
        message: Message(messageId: id, fromId: 1, date: Date(), text: "context \(id)",
                         peerUserId: nil, peerThreadId: 10, chatId: 10, rev: id, sourceSnapshot: "snapshot-\(id)"),
        reactions: [], repliedToMessage: nil, attachments: [])
      if id == 3 {
        full.photoInfo = PhotoInfo(photo: Photo(photoId: 77, format: .jpeg),
          sizes: [PhotoSize(photoId: 77, localPath: "selected.jpg")])
      }
      return full
    }
    let entities = MessageEntities.with {
      $0.entities = [.with { $0.type = .mention; $0.offset = 0; $0.length = 4; $0.mention.userID = 9 }]
    }
    return DiscussionCarryOverDraft(authorUserId: 1, messages: messages, destination: .anchored,
      reservedChatId: 20, topic: nil, botUserId: 9, instruction: "@Bot current direction",
      instructionEntities: entities, activationRandomId: 13, forwardingRandomIds: [11, 12])
  }

  @Test("final durable clear rejects an account change while its real verification read is held", arguments: [
    "otherUser", "credentialRefresh", "logoutRelogin",
  ])
  func clearAccountChangesDuringVerification(replacement: String) async throws {
    let database = AppDatabase.empty()
    let auth = Auth.mocked(authenticated: false)
    try await auth.saveCredentials(token: "1:clear-test-only", userId: 1)
    let drafts = Drafts2(database: database, auth: auth.handle)
    let peer = Peer.thread(id: 10)
    let draft = intent()
    try await drafts.saveDiscussionCarryOver(peer: peer, draft: draft)
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let gate = CarryOverVerificationGate(started: continuation)
    let clearing = Task {
      try await drafts.saveDiscussionCarryOver(peer: peer, draft: nil, expectedReservationId: draft.reservedChatId,
        verificationRead: {
          let actual = try await database.reader.read { try Drafts2Row.fetchOne($0, key: peer.toString())?.discussionCarryOver }
          #expect(actual == nil)
          await gate.hold()
          return actual
        })
    }
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(3))
      continuation.finish()
      await gate.release()
    }
    defer { watchdog.cancel(); continuation.finish() }
    var verifications = started.makeAsyncIterator()
    _ = await verifications.next()
    if replacement == "logoutRelogin" {
      let fence = try auth.beginLogoutSynchronously()
      let proof = try #require(await auth.destroyCredentialsForPendingLogout(fence: fence))
      #expect(await LogoutCompletionCoordinator.complete(fence: fence,
        databaseProof: AuthDatabaseCleanupProof(fence: fence), credentialProof: proof,
        completionPermit: AuthLogoutCompletionPermit(fence: fence), auth: auth))
    }
    let replacementUserId: Int64 = replacement == "otherUser" ? 2 : 1
    try await auth.saveCredentials(token: "\(replacementUserId):clear-replacement-test-only", userId: replacementUserId)
    await gate.release()
    if replacement == "credentialRefresh" {
      // A same-account token renewal retains its account incarnation.
      try await clearing.value
    } else {
      await #expect(throws: (any Error).self) { try await clearing.value }
    }
  }

  @Test("immutable selection, media, entity and submission identity round trip through the existing draft")
  func persistence() async throws {
    let database = AppDatabase.empty()
    let drafts = Drafts2(database: database)
    let peer = Peer.thread(id: 10)
    let draft = intent()
    drafts.updateText(peer: peer, text: "unrelated source draft")
    try await drafts.saveDiscussionCarryOver(peer: peer, draft: draft)
    let restored = Drafts2(database: database).load(peer: peer)
    #expect(restored?.discussionCarryOver == draft)
    #expect(restored?.text == "unrelated source draft")
    drafts.clear(peer: peer)
    await drafts.flush()
    #expect(Drafts2(database: database).load(peer: peer)?.discussionCarryOver == draft)
    #expect(Drafts2(database: database).load(peer: peer)?.isEmpty == true)
    try await drafts.saveDiscussionCarryOver(peer: peer, draft: nil)
    #expect(Drafts2(database: database).load(peer: peer) == nil)
  }

  @Test("existing anchor only opens without seed, worker membership, or activation")
  func existingChild() async throws {
    let recorder = Recorder()
    let draft = intent()
    let outcome = try await runner(recorder, destinationId: 99).submit(draft)
    #expect(outcome == .openedExisting(.thread(id: 99)))
    #expect(await recorder.events == ["persist", "create"])
  }

  @Test("seed failure cannot activate the bot and retry retains the exact original selection IDs")
  func failedSeed() async throws {
    let recorder = Recorder(failAt: "forward")
    let draft = intent()
    await #expect(throws: Failure.self) { try await runner(recorder).submit(draft) }
    #expect(await recorder.events == ["persist", "create", "forward"])
    let persisted = try #require(await recorder.persisted)
    #expect(persisted == draft)
    await recorder.setFailure(nil)
    _ = try await runner(recorder).submit(persisted)
    #expect(await recorder.forwarded.map(\.forwardingRandomIds) == [[11, 12], [11, 12]])
    #expect(await recorder.events.suffix(3) == ["persist", "add", "activate"])
  }

  @Test("confirmed seed is durably saved before membership and an activation retry rechecks exact receipt identities")
  func failedActivation() async throws {
    let recorder = Recorder(failAt: "activate")
    await #expect(throws: Failure.self) { try await runner(recorder).submit(intent()) }
    let persisted = try #require(await recorder.persisted)
    #expect(persisted.seedComplete)
    #expect(await recorder.events == ["persist", "create", "forward", "persist", "add", "activate"])
    await recorder.setFailure(nil)
    _ = try await runner(recorder).submit(persisted)
    #expect(await recorder.forwarded.count == 2)
    #expect(await recorder.forwarded.map(\.forwardingRandomIds) == [[11, 12], [11, 12]])
    #expect(await recorder.activated.map(\.activationRandomId) == [13, 13])
  }

  @Test("failed durable checkpoint after forwarding cannot grant bot access")
  func checkpointFailure() async throws {
    let recorder = Recorder(failCheckpoint: true)
    await #expect(throws: Failure.self) { try await runner(recorder).submit(intent()) }
    #expect(await recorder.events == ["persist", "create", "forward", "persist"])
    #expect(await recorder.persisted?.seedComplete == false)
  }

  @Test("a completed seed must still pass receipt reconciliation before any worker operation")
  func deletedConfirmedSeed() async throws {
    let recorder = Recorder(failAt: "forward")
    var completed = intent()
    completed.seedComplete = true
    await #expect(throws: Failure.self) { try await runner(recorder).submit(completed) }
    #expect(await recorder.events == ["persist", "create", "forward"])
    #expect(await recorder.activated.isEmpty)
  }

  @Test("another window cannot replace or clear an unfinished reservation")
  func oneSubmissionPerSource() async throws {
    let database = AppDatabase.empty()
    let drafts = Drafts2(database: database)
    let original = intent()
    let peer = Peer.thread(id: 10)
    try await drafts.saveDiscussionCarryOver(peer: peer, draft: original)
    let other = DiscussionCarryOverDraft(authorUserId: original.authorUserId, messages: original.messages,
      destination: .independent, reservedChatId: 21, topic: nil, botUserId: nil,
      instruction: "Other task", instructionEntities: nil)
    await #expect(throws: DiscussionCarryOverPersistenceError.self) {
      try await drafts.saveDiscussionCarryOver(peer: peer, draft: other)
    }
    await #expect(throws: DiscussionCarryOverPersistenceError.self) {
      try await drafts.saveDiscussionCarryOver(peer: peer, draft: nil, expectedReservationId: 21)
    }
    let changed = DiscussionCarryOverDraft(authorUserId: original.authorUserId, messages: original.messages,
      destination: original.destination, reservedChatId: original.reservedChatId, topic: nil, botUserId: nil,
      instruction: "changed payload", instructionEntities: nil,
      activationRandomId: original.activationRandomId, forwardingRandomIds: original.forwardingRandomIds)
    await #expect(throws: DiscussionCarryOverPersistenceError.self) {
      try await drafts.saveDiscussionCarryOver(peer: peer, draft: changed)
    }
    #expect(drafts.cached(peer: peer)?.discussionCarryOver == original)
    var complete = original
    complete.seedComplete = true
    try await drafts.saveDiscussionCarryOver(peer: peer, draft: complete)
    // A second window can replay its older checkpoint, but cannot erase it.
    try await drafts.saveDiscussionCarryOver(peer: peer, draft: original)
    #expect(drafts.cached(peer: peer)?.discussionCarryOver?.seedComplete == true)
  }

  @Test("preview includes carried task state, historical action labels and source links without a quoted parent")
  func preview() {
    var full = intent().messages[0]
    full.message.repliedToMessageId = 2
    full.message.actions = .with {
      $0.rows = [.with { $0.actions = [.with { $0.actionID = "live-callback"; $0.text = "Approve" },
                                     .with { $0.text = "Reject" }] }]
    }
    full.attachments = [.init(attachment: .init(messageId: nil, externalTaskId: nil, urlPreviewId: nil, attachmentId: nil),
      externalTask: ExternalTask(from: .with {
        $0.application = "Kata"; $0.number = "42"; $0.title = "Investigate"; $0.status = .done
        $0.assignedUserID = 8; $0.url = "https://tasks.invalid/42"
      }))]
    #expect(full.discussionCarryOverText == "context 3\n\nKata · 42 · Investigate\n\nStatus: Done\n\nAssignee: inline://user/8\n\nhttps://tasks.invalid/42\n\nApprove · Reject\n\nReply: inline://chat/10?message_id=2\n\nSource: inline://chat/10?message_id=3")
    #expect(!full.discussionCarryOverText.contains("live-callback"))
  }

  @Test("only an explicit matching old intent can replace a saved submission with entirely fresh identities")
  func explicitReplacement() async throws {
    let database = AppDatabase.empty()
    let drafts = Drafts2(database: database)
    let old = intent()
    let peer = Peer.thread(id: 10)
    drafts.updateText(peer: peer, text: "source composer still belongs to the human")
    try await drafts.saveDiscussionCarryOver(peer: peer, draft: old)
    let replacement = DiscussionCarryOverDraft(authorUserId: 1, messages: old.messages, destination: .independent,
      reservedChatId: 30, topic: nil, botUserId: old.botUserId, instruction: old.instruction,
      instructionEntities: old.instructionEntities, activationRandomId: 33, forwardingRandomIds: [31, 32])
    await #expect(throws: DiscussionCarryOverPersistenceError.self) {
      try await drafts.saveDiscussionCarryOver(peer: peer, draft: replacement)
    }
    try await drafts.saveDiscussionCarryOver(peer: peer, draft: replacement, replacing: old)
    #expect(drafts.cached(peer: peer)?.discussionCarryOver == replacement)
    #expect(drafts.cached(peer: peer)?.text == "source composer still belongs to the human")
    // A stale window cannot clear or replace the new reservation afterward.
    await #expect(throws: DiscussionCarryOverPersistenceError.self) {
      try await drafts.saveDiscussionCarryOver(peer: peer, draft: old, replacing: old)
    }
    #expect(Drafts2(database: database).load(peer: peer)?.discussionCarryOver == replacement)
  }

  @Test("explicit replacement while an old participant RPC is held prevents the old activation")
  func retiresOldContinuation() async throws {
    let drafts = Drafts2(database: .empty())
    let old = intent()
    let peer = Peer.thread(id: 10)
    let recorder = Recorder()
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let gate = ParticipantGate(started: continuation)
    let submission = DiscussionCarryOverSubmission(
      persist: { try await drafts.saveDiscussionCarryOver(peer: peer, draft: $0) },
      admit: { try drafts.requireCurrentDiscussionCarryOver(peer: peer, draft: $0) },
      create: { $0.reservedChatId }, forward: { _ in },
      addParticipant: { _, _ in await gate.wait() }, activate: { try await recorder.activate($0) })
    let running = Task { try await submission.submit(old) }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    let replacement = DiscussionCarryOverDraft(authorUserId: 1, messages: old.messages, destination: .independent,
      reservedChatId: 30, topic: nil, botUserId: old.botUserId, instruction: old.instruction,
      instructionEntities: old.instructionEntities, activationRandomId: 33, forwardingRandomIds: [31, 32])
    try await drafts.saveDiscussionCarryOver(peer: peer, draft: replacement, replacing: old)
    await gate.release()
    await #expect(throws: DiscussionCarryOverPersistenceError.self) { try await running.value }
    #expect(await recorder.activated.isEmpty)
    #expect(drafts.cached(peer: peer)?.discussionCarryOver == replacement)
  }

  @Test("stable activation keeps its identity through persistence without creating a negative optimistic row")
  func stableActivation() async throws {
    let transaction = SendMessageTransaction(text: "@Bot current direction", peerId: .thread(id: 20),
      chatId: 20, randomId: 13, deferLocalMessage: true)
    let encoded = try JSONEncoder().encode(transaction.context)
    let restored = try JSONDecoder().decode(SendMessageTransaction.Context.self, from: encoded)
    #expect(restored.randomId == 13)
    #expect(restored.deferLocalMessage)
    #expect(await transaction.validateOptimisticState())
    if case let .sendMessage(input)? = transaction.input(from: restored) {
      #expect(input.randomID == 13)
    } else { Issue.record("missing stable send input") }
    let ordinary = SendMessageTransaction(text: "normal", peerId: .thread(id: 20), chatId: 20)
    let legacy = try JSONEncoder().encode(ordinary.context)
    #expect(!String(decoding: legacy, as: UTF8.self).contains("deferLocalMessage"))
    #expect(try JSONDecoder().decode(SendMessageTransaction.Context.self, from: legacy).deferLocalMessage == false)
  }

  @Test("review uses the exact authorized wire snapshot over stale warm media and attachments")
  func exactSnapshot() {
    var cached = intent().messages[0]
    cached.attachments = [.init(attachment: .init(messageId: nil, externalTaskId: nil, urlPreviewId: nil, attachmentId: 7),
      externalTask: ExternalTask(application: "Kata", taskId: "old", status: .todo,
        assignedUserId: nil, url: nil, title: "removed", date: nil, number: nil))]
    let wire = InlineProtocol.Message.with {
      $0.id = 3; $0.chatID = 10; $0.fromID = 1; $0.peerID.chat.chatID = 10
      $0.message = "fresh body"; $0.rev = 4; $0.sourceSnapshot = "authoritative-token"
      $0.media.nudge = .init()
    }
    let reviewed = cached.reviewedCarryOverSnapshot(from: wire)
    #expect(reviewed.message.sourceSnapshot == "authoritative-token")
    #expect(reviewed.message.rev == 4)
    #expect(reviewed.message.text == "fresh body\n\n👋 Nudge")
    #expect(reviewed.photoInfo == nil)
    #expect(reviewed.attachments.isEmpty)
    #expect(reviewed.discussionCarryOverText == "fresh body\n\n👋 Nudge\n\nSource: inline://chat/10?message_id=3")
  }

  @Test("reserved child identity survives durable transaction encoding and uses existing anchor input")
  func reservedChild() throws {
    let transaction = CreateSubthreadTransaction(parentChatId: 10, parentMessageId: 3, reservedChatId: 20)
    let restored = try JSONDecoder().decode(CreateSubthreadTransaction.Context.self, from: JSONEncoder().encode(transaction.context))
    #expect(restored.reservedChatId == 20)
    #expect(restored.agentContext == nil)
    if case let .createSubthread(input)? = transaction.input(from: restored) {
      #expect(input.parentChatID == 10)
      #expect(input.parentMessageID == 3)
      #expect(input.reservedChatID == 20)
      #expect(!input.hasAgentContext)
    } else { Issue.record("missing reserved child input") }
    let ordinary = CreateSubthreadTransaction(parentChatId: 10, parentMessageId: 3)
    #expect(ordinary.reconnectReplayPolicy == nil)
    #expect(transaction.reconnectReplayPolicy != nil)
  }

  private func runner(_ recorder: Recorder, destinationId: Int64 = 20) -> DiscussionCarryOverSubmission {
    DiscussionCarryOverSubmission(
      persist: { try await recorder.save($0) },
      admit: { try await recorder.admit($0) },
      create: { draft in try await recorder.record("create"); return destinationId },
      forward: { try await recorder.forward($0) },
      addParticipant: { _, _ in try await recorder.record("add") },
      activate: { try await recorder.activate($0) }
    )
  }

  private enum Failure: Error { case operation }
  private actor ParticipantGate {
    let started: AsyncStream<Void>.Continuation
    var continuation: CheckedContinuation<Void, Never>?
    init(started: AsyncStream<Void>.Continuation) { self.started = started }
    func wait() async {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        started.yield(())
        started.finish()
      }
    }
    func release() { continuation?.resume(); continuation = nil }
  }
  private actor Recorder {
    var events: [String] = []
    var persisted: DiscussionCarryOverDraft?
    var forwarded: [DiscussionCarryOverDraft] = []
    var activated: [DiscussionCarryOverDraft] = []
    var failAt: String?
    let failCheckpoint: Bool
    init(failAt: String? = nil, failCheckpoint: Bool = false) { self.failAt = failAt; self.failCheckpoint = failCheckpoint }
    func setFailure(_ value: String?) { failAt = value }
    func record(_ event: String) throws {
      events.append(event)
      if event == failAt { throw Failure.operation }
    }
    func save(_ draft: DiscussionCarryOverDraft) throws {
      try record("persist")
      if failCheckpoint && draft.seedComplete { throw Failure.operation }
      persisted = draft
    }
    func admit(_ draft: DiscussionCarryOverDraft) throws {
      guard persisted?.hasSameSubmission(as: draft) == true else { throw Failure.operation }
    }
    func forward(_ draft: DiscussionCarryOverDraft) throws { forwarded.append(draft); try record("forward") }
    func activate(_ draft: DiscussionCarryOverDraft) throws { activated.append(draft); try record("activate") }
  }
}

private actor CarryOverVerificationGate {
  let started: AsyncStream<Void>.Continuation
  private var waiter: CheckedContinuation<Void, Never>?
  init(started: AsyncStream<Void>.Continuation) { self.started = started }
  func hold() async {
    await withCheckedContinuation { continuation in
      waiter = continuation
      started.yield(())
      started.finish()
    }
  }
  func release() { waiter?.resume(); waiter = nil }
}
