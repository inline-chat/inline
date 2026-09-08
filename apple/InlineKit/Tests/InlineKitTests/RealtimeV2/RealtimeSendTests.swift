import AsyncAlgorithms
import Foundation
import InlineProtocol
import Testing

@testable import Auth
@testable import RealtimeV2

// These transport fixtures leave sync discovery pending. A connected or updating session can
// send; settled connection presentation is covered separately by the sync presentation suites.
@Suite("RealtimeV2.Send", .serialized)
final class RealtimeSendTests {
  @Test("onboarding profile submission waits for the authenticated V3 connection")
  func testOnboardingWaitsForConnection() async throws {
    let auth = Auth.mocked(authenticated: true)
    let account = try auth.handle.beginAccountMutation()
    let transport = DelayedOnboardingTransport()
    let realtime = RealtimeV2(transport: transport, auth: auth.handle,
                              applyUpdates: SendTestApplyUpdates(), syncStorage: SendTestSyncStorage())
    let save = Task {
      try await realtime.withUserInitiatedConnection(accountToken: account, timeout: .seconds(3)) { realtime in
        try await realtime.updateProfile(firstName: "Test", lastName: "Person", bio: nil)
      }
    }
    #expect(await waitForCondition(timeout: .seconds(1)) { await transport.started })
    #expect(await transport.profileCalls == 0)
    await transport.allowConnection()
    let result = try await save.value
    #expect(result.user.firstName == "Test")
    #expect(await transport.profileCalls == 1)
    await realtime.loggedOut()
  }

  @Test("external command RPCs and response updates reject stale account generations")
  func testExternalCommandRejectsStaleAccount() async throws {
    let auth = Auth.mocked(authenticated: true)
    let current = try auth.handle.beginAccountMutation()
    let transport = MockTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )
    let staleTokens = [
      AuthAccountMutationToken(generation: current.generation &+ 1, userID: current.userID),
      AuthAccountMutationToken(generation: current.generation, userID: Int64.max),
    ]
    for token in staleTokens {
      await #expect(throws: AuthStorageError.self) {
        try await realtime.withUserInitiatedConnection(accountToken: token) { _ in
          Issue.record("Stale account work must not begin")
        }
      }
      await #expect(throws: AuthStorageError.self) {
        try await realtime.callRpcDirect(method: .sendMessage, input: .sendMessage(.init()), accountToken: token)
      }
      await #expect(throws: AuthStorageError.self) {
        try await realtime.applyUpdatesAndWait([], accountToken: token)
      }
    }
    #expect(await transport.sentMessages.contains { message in
      if case .rpcCall = message.body { return true }
      return false
    } == false)
    await realtime.loggedOut()
  }

  @Test("user-initiated connection deadline cancels admitted work and permits the next operation")
  func testUserInitiatedDeadlineAndCancellation() async throws {
    let auth = Auth.mocked(authenticated: true)
    let account = try auth.handle.beginAccountMutation()
    let realtime = RealtimeV2(
      transport: HangingRpcTransport(), auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(), syncStorage: SendTestSyncStorage()
    )
    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: RealtimeDirectRpcError.self) {
      try await realtime.withUserInitiatedConnection(accountToken: account, timeout: .milliseconds(150)) { _ in
        try await Task.sleep(for: .seconds(30))
      }
    }
    #expect(clock.now - start < .seconds(3))
    let result = try await realtime.withUserInitiatedConnection(accountToken: account) { _ in 7 }
    #expect(result == 7)
    let admitted = SendTestFlag()
    let task = Task {
      try await realtime.withUserInitiatedConnection(accountToken: account) { _ in
        await admitted.set()
        try await Task.sleep(for: .seconds(30))
      }
    }
    #expect(await waitForCondition(timeout: .seconds(2)) { await admitted.get() })
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await realtime.loggedOut()
  }

  @Test("termination cancels system work, drains its cleanup, and rejects new admission")
  func testUserInitiatedConnectionTermination() async throws {
    let auth = Auth.mocked(authenticated: true)
    let account = try auth.handle.beginAccountMutation()
    let realtime = RealtimeV2(transport: HangingRpcTransport(), auth: auth.handle,
                              applyUpdates: SendTestApplyUpdates(), syncStorage: SendTestSyncStorage())
    let admitted = SendTestFlag()
    let cleanedUp = SendTestFlag()
    let task = Task {
      try await realtime.withUserInitiatedConnection(accountToken: account) { _ in
        await admitted.set()
        do { try await Task.sleep(for: .seconds(30)) }
        catch {
          // Like an async DB API, cleanup finishes before its task returns after cancellation.
          await cleanedUp.set()
          throw error
        }
      }
    }
    #expect(await waitForCondition(timeout: .seconds(2)) { await admitted.get() })
    await realtime.prepareForTermination()
    #expect(await cleanedUp.get())
    await #expect(throws: CancellationError.self) { try await task.value }
    await #expect(throws: CancellationError.self) {
      try await realtime.withUserInitiatedConnection(accountToken: account) { _ in
        Issue.record("No system action may begin after termination admission closes")
      }
    }
  }

  @Test("nested system sends reject an account replacement without deadlocking its owner drain", arguments: [false, true])
  func testNestedSystemSendDuringAccountReplacement(sameUser: Bool) async throws {
    await SendTestRecorder.shared.reset()
    let auth = Auth.mocked(authenticated: true)
    let account = try auth.handle.beginAccountMutation()
    let realtime = RealtimeV2(transport: HangingRpcTransport(), auth: auth.handle,
                              applyUpdates: SendTestApplyUpdates(), syncStorage: SendTestSyncStorage())
    let finished = SendTestFlag()
    let id = UUID()
    let operation = Task {
      do {
        try await realtime.withUserInitiatedConnection(accountToken: account) { realtime in
          try await auth.saveCredentials(token: "2:test-replacement", userId: sameUser ? account.userID : account.userID + 1)
          _ = try await realtime.send(SendTestTransaction(id: id), expectedAccount: account)
          Issue.record("Stale send must be rejected")
        }
      } catch {
        // Either account validation or owner admission rejects the replaced generation.
      }
      await finished.set()
    }
    let didFinish = await waitForCondition(timeout: .seconds(3)) { await finished.get() }
    #expect(didFinish)
    #expect(await SendTestRecorder.shared.didRunOptimistic(id) == false)
    operation.cancel()
    if didFinish { await realtime.prepareForTermination() }
  }

  @Test("a send resolved for another account or generation is rejected before optimistic work or dispatch")
  func testExpectedAccountRejectsStaleTarget() async throws {
    await SendTestRecorder.shared.reset()
    let auth = Auth.mocked(authenticated: true)
    let current = try auth.handle.beginAccountMutation()
    let transport = MockTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )
    let staleTokens = [
      AuthAccountMutationToken(generation: current.generation &+ 1, userID: current.userID),
      AuthAccountMutationToken(generation: current.generation, userID: Int64.max),
    ]
    for token in staleTokens {
      let id = UUID()
      await #expect(throws: (any Error).self) {
        try await realtime.send(SendTestTransaction(id: id), expectedAccount: token)
      }
      #expect(await SendTestRecorder.shared.didRunOptimistic(id) == false)
    }
    #expect(await transport.sentMessages.contains { message in
      if case .rpcCall = message.body { return true }
      return false
    } == false)
    await realtime.loggedOut()
  }

  @Test("first update after protocol open uses the manager session generation")
  func testImmediateFirstSessionUpdateIsApplied() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = ImmediateOpenUpdateTransport()
    let apply = ImmediateUpdateApplyRecorder()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: SendTestSyncStorage()
    )

    let applied = await waitForCondition(timeout: .seconds(10)) {
      await apply.count > 0
    }
    #expect(applied)

    await realtime.loggedOut()
  }

  @Test("local-data reset resumes the authenticated transaction owner")
  func testLocalDataResetResume() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    await realtime.loggedOut()

    let blockedID = UUID()
    let rpcCallsBeforeBlockedTransaction = await transport.sentMessages.count { message in
      if case .rpcCall = message.body { return true }
      return false
    }
    _ = await realtime.sendQueued(SendTestTransaction(id: blockedID))
    let rpcCallsAfterBlockedTransaction = await transport.sentMessages.count { message in
      if case .rpcCall = message.body { return true }
      return false
    }
    #expect(rpcCallsAfterBlockedTransaction == rpcCallsBeforeBlockedTransaction)

    await realtime.resumeAfterLocalDataReset()

    let resumedID = UUID()
    _ = await realtime.sendQueued(SendTestTransaction(id: resumedID))
    #expect(await SendTestRecorder.shared.didRunOptimistic(resumedID))
    let dispatched = await waitForCondition(timeout: .seconds(2)) {
      await !transport.sentMessages.isEmpty
    }
    #expect(dispatched)

    await realtime.loggedOut()
  }

  @Test("authenticated sendQueued runs optimistic immediately")
  func testAuthenticatedSendQueuedRunsOptimisticImmediately() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let id = UUID()
    _ = await realtime.sendQueued(SendTestTransaction(id: id))

    let optimisticRan = await SendTestRecorder.shared.didRunOptimistic(id)
    #expect(optimisticRan)

    withExtendedLifetime(realtime) {}
  }

  @Test("sendQueuedIfAccepted reports durable admission")
  func testSendQueuedIfAcceptedReportsAdmission() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let realtime = RealtimeV2(
      transport: MockTransport(),
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let id = UUID()
    let transactionID = await realtime.sendQueuedIfAccepted(SendTestTransaction(id: id))

    #expect(transactionID != nil)
    #expect(await SendTestRecorder.shared.didRunOptimistic(id))
    withExtendedLifetime(realtime) {}
  }

  @Test("sendQueuedIfAccepted rejects missing optimistic state before persistence")
  func testSendQueuedIfAcceptedRejectsMissingOptimisticState() async throws {
    await OptimisticValidationRecorder.shared.reset()

    let transport = MockTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: Auth.mocked(authenticated: true).handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let transactionID = await realtime.sendQueuedIfAccepted(RejectedOptimisticStateTransaction())

    #expect(transactionID == nil)
    #expect(await OptimisticValidationRecorder.shared.optimisticCount() == 1)
    #expect(await OptimisticValidationRecorder.shared.cancelledCount() == 1)
    #expect(await transport.sentMessages.contains { message in
      if case .rpcCall = message.body { return true }
      return false
    } == false)
    withExtendedLifetime(realtime) {}
  }

  @Test("unauthenticated sendQueued rejects before optimistic work")
  func testUnauthenticatedSendQueuedRejectsBeforeOptimisticWork() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: false)
    let realtime = RealtimeV2(
      transport: MockTransport(),
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let id = UUID()
    _ = await realtime.sendQueued(SendTestTransaction(id: id))

    #expect(await SendTestRecorder.shared.didRunOptimistic(id) == false)
    withExtendedLifetime(realtime) {}
  }

  @Test("sendQueuedIfAccepted reports unauthenticated rejection")
  func testSendQueuedIfAcceptedReportsUnauthenticatedRejection() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: false)
    let realtime = RealtimeV2(
      transport: MockTransport(),
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let id = UUID()
    let transactionID = await realtime.sendQueuedIfAccepted(SendTestTransaction(id: id))

    #expect(transactionID == nil)
    #expect(await SendTestRecorder.shared.didRunOptimistic(id) == false)
    withExtendedLifetime(realtime) {}
  }

  @Test("send rejects an account switch during optimistic work")
  func testSendRejectsAccountSwitchDuringOptimisticWork() async throws {
    let auth = Auth.mocked(authenticated: true)
    await AccountSwitchSendRecorder.shared.reset {
      try? await auth.saveCredentials(token: "2:replacementToken", userId: 2)
    }
    let transport = AccountSwitchSendTransport()
    let persistence = AccountSwitchSendPersistence()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage(),
      persistenceHandler: persistence
    )

    let id = UUID()
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          _ = try await realtime.send(AccountSwitchSendTransaction(id: id))
        }
        group.addTask {
          try await Task.sleep(for: .seconds(2))
          throw SendTestTimeoutError.timedOut
        }
        _ = try await group.next()
        group.cancelAll()
      }
      Issue.record("Expected account-switch cancellation")
    } catch is CancellationError {
      // Expected.
    } catch SendTestTimeoutError.timedOut {
      Issue.record("Timed out waiting for account-switch cancellation")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(await AccountSwitchSendRecorder.shared.optimisticCount(id) == 1)
    #expect(await AccountSwitchSendRecorder.shared.cancelledCount(id) == 1)
    #expect(await AccountSwitchSendRecorder.shared.applyCount(id) == 0)
    #expect(await AccountSwitchSendRecorder.shared.failedCount(id) == 0)
    #expect(await transport.didDispatchAccountSwitchMutation() == false)

    await realtime.loggedOut()
    #expect(await persistence.savedOwners().isEmpty)
  }

  @Test("sendQueued rejects an account switch during optimistic work")
  func testSendQueuedRejectsAccountSwitchDuringOptimisticWork() async throws {
    let auth = Auth.mocked(authenticated: true)
    await AccountSwitchSendRecorder.shared.reset {
      try? await auth.saveCredentials(token: "2:replacementToken", userId: 2)
    }
    let transport = AccountSwitchSendTransport()
    let persistence = AccountSwitchSendPersistence()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage(),
      persistenceHandler: persistence
    )

    let id = UUID()
    _ = await realtime.sendQueued(AccountSwitchSendTransaction(id: id))

    #expect(await AccountSwitchSendRecorder.shared.optimisticCount(id) == 1)
    #expect(await AccountSwitchSendRecorder.shared.cancelledCount(id) == 1)
    #expect(await AccountSwitchSendRecorder.shared.applyCount(id) == 0)
    #expect(await AccountSwitchSendRecorder.shared.failedCount(id) == 0)
    #expect(await transport.didDispatchAccountSwitchMutation() == false)

    await realtime.loggedOut()
    #expect(await persistence.savedOwners().isEmpty)
  }

  @Test("send rejects a durable mutation when persistence fails")
  func testSendRejectsDurableMutationWhenPersistenceFails() async throws {
    await AccountSwitchSendRecorder.shared.reset()
    let auth = Auth.mocked(authenticated: true)
    let transport = AccountSwitchSendTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage(),
      persistenceHandler: FailingAccountSwitchSendPersistence()
    )

    let id = UUID()
    do {
      _ = try await realtime.send(AccountSwitchSendTransaction(id: id))
      Issue.record("Expected persistence admission failure")
    } catch let error as TransactionError {
      guard case .persistenceFailed = error else {
        Issue.record("Unexpected transaction error: \(error)")
        return
      }
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(await AccountSwitchSendRecorder.shared.optimisticCount(id) == 1)
    #expect(await AccountSwitchSendRecorder.shared.cancelledCount(id) == 1)
    #expect(await AccountSwitchSendRecorder.shared.applyCount(id) == 0)
    #expect(await AccountSwitchSendRecorder.shared.failedCount(id) == 0)
    #expect(await transport.didDispatchAccountSwitchMutation() == false)
    await realtime.loggedOut()
  }

  @Test("sendQueuedIfAccepted reports persistence rejection")
  func testSendQueuedIfAcceptedReportsPersistenceRejection() async throws {
    await AccountSwitchSendRecorder.shared.reset()
    let auth = Auth.mocked(authenticated: true)
    let transport = AccountSwitchSendTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage(),
      persistenceHandler: FailingAccountSwitchSendPersistence()
    )

    let id = UUID()
    let transactionID = await realtime.sendQueuedIfAccepted(AccountSwitchSendTransaction(id: id))

    #expect(transactionID == nil)
    #expect(await AccountSwitchSendRecorder.shared.optimisticCount(id) == 1)
    #expect(await AccountSwitchSendRecorder.shared.cancelledCount(id) == 1)
    #expect(await transport.didDispatchAccountSwitchMutation() == false)
    await realtime.loggedOut()
  }

  @Test("send completes with immediate rpc response")
  func testSendCompletesWithImmediateRpcResponse() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = ImmediateRoundTripTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected || stateObject.connectionState == .updating
      }
    }
    #expect(connected)

    let id = UUID()
    let result = try await realtime.send(SendTestTransaction(id: id))
    #expect(result == nil)
    #expect(await SendTestRecorder.shared.didRunOptimistic(id))
    #expect(await SendTestRecorder.shared.didRunApply(id))

    withExtendedLifetime(realtime) {}
  }

  @Test("transaction drain multiplexes writes before any RPC response")
  func testTransactionDrainMultiplexesWritesBeforeResponses() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = HeldResultTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run { stateObject.connectionState == .connected || stateObject.connectionState == .updating }
    }
    #expect(connected)

    let firstID = UUID()
    let secondID = UUID()
    let first = Task {
      try await realtime.send(SendTestTransaction(id: firstID, method: multiplexedSendMethod))
    }
    let second = Task {
      try await realtime.send(SendTestTransaction(id: secondID, method: multiplexedSendMethod))
    }

    let bothWritten = await waitForCondition {
      await transport.pendingMultiplexedResultCount == 2
    }
    #expect(bothWritten)
    #expect(await SendTestRecorder.shared.didRunApply(firstID) == false)
    #expect(await SendTestRecorder.shared.didRunApply(secondID) == false)

    await transport.completePendingResultsInReverseOrder()
    _ = try await first.value
    _ = try await second.value

    #expect(await SendTestRecorder.shared.didRunApply(firstID))
    #expect(await SendTestRecorder.shared.didRunApply(secondID))
    withExtendedLifetime(realtime) {}
  }

  @Test("transaction drain holds bursts inside the application request window")
  func testTransactionDrainBoundsBurstAdmission() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = HeldResultTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run { stateObject.connectionState == .connected || stateObject.connectionState == .updating }
    }
    #expect(connected)

    let sends = (0 ..< 40).map { _ in
      Task {
        try await realtime.send(
          SendTestTransaction(id: UUID(), method: multiplexedSendMethod)
        )
      }
    }
    defer { sends.forEach { $0.cancel() } }

    let firstWindowFilled = await waitForCondition(timeout: .seconds(2)) {
      await transport.pendingMultiplexedResultCount == 32
    }
    guard firstWindowFilled else {
      Issue.record("Expected the first 32 requests to fill the application window")
      return
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await transport.pendingMultiplexedResultCount == 32)

    await transport.completePendingResults(limit: 32)
    let secondWindowDispatched = await waitForCondition(timeout: .seconds(2)) {
      await transport.pendingMultiplexedResultCount == 8
    }
    guard secondWindowDispatched else {
      let pending = await transport.pendingMultiplexedResultCount
      Issue.record("Expected the remaining eight requests after capacity reopened; observed \(pending)")
      return
    }
    await transport.completePendingResults(limit: 8)

    for send in sends {
      _ = try await send.value
    }
    withExtendedLifetime(realtime) {}
  }

  @Test("deferred transaction waits for retry signal instead of spinning")
  func testDeferredTransactionWaitsForRetrySignal() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = FailOnceTransactionTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run { stateObject.connectionState == .connected || stateObject.connectionState == .updating }
    }
    #expect(connected)

    let sending = Task {
      try await realtime.send(SendTestTransaction(id: UUID(), method: deferredSpinMethod))
    }
    let firstAttempt = await waitForCondition {
      await transport.targetAttemptCount == 1
    }
    #expect(firstAttempt)
    try await Task.sleep(for: .milliseconds(150))
    #expect(await transport.targetAttemptCount == 1)

    _ = try await sending.value
    #expect(await transport.targetAttemptCount == 2)
    withExtendedLifetime(realtime) {}
  }

  @Test("pre-write not-connected requeues a non-replayable mutation")
  func testPreWriteNotConnectedRequeuesNonReplayableMutation() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = PreWriteNotConnectedTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run { stateObject.connectionState == .connected || stateObject.connectionState == .updating }
    }
    #expect(connected)

    let sending = Task {
      try await realtime.send(
        SendTestTransaction(
          id: UUID(),
          method: preWriteMutationMethod,
          type: .mutation()
        )
      )
    }

    _ = try await sending.value
    #expect(await transport.targetAttemptCount == 2)
    withExtendedLifetime(realtime) {}
  }

  @Test("pre-write capacity rejection requeues a non-replayable mutation")
  func testPreWriteCapacityRejectionRequeuesNonReplayableMutation() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = PreWriteCapacityTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run { stateObject.connectionState == .connected || stateObject.connectionState == .updating }
    }
    #expect(connected)

    _ = try await realtime.send(
      SendTestTransaction(
        id: UUID(),
        method: preWriteCapacityMethod,
        type: .mutation()
      )
    )

    #expect(await transport.targetAttemptCount == 2)
    withExtendedLifetime(realtime) {}
  }

  @Test("server 503 redelivers a non-replayable mutation after bounded backoff")
  func testRejectedBeforeExecutionRedeliversAfterBackoff() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = RejectedBeforeExecutionTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run { stateObject.connectionState == .connected || stateObject.connectionState == .updating }
    }
    #expect(connected)

    let send = Task {
      try await realtime.send(
        SendTestTransaction(
          id: UUID(),
          method: rejectedBeforeExecutionMethod,
          type: .mutation()
        )
      )
    }
    let firstAttempt = await waitForCondition(timeout: .seconds(1)) {
      await transport.targetAttemptCount == 1
    }
    guard firstAttempt else {
      Issue.record("Expected the first request attempt")
      return
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await transport.targetAttemptCount == 1)

    let retried = await waitForCondition(timeout: .seconds(2)) {
      await transport.targetAttemptCount == 2
    }
    guard retried else {
      send.cancel()
      Issue.record("Expected rejected-before-execution work to retry after backoff")
      return
    }
    _ = try await send.value
    let stateObject = realtime.stateObject
    #expect(await MainActor.run { stateObject.connectionState == .connected || stateObject.connectionState == .updating })
    withExtendedLifetime(realtime) {}
  }

  @Test("protobuf application status 503 is not treated as a carrier rejection")
  func testApplicationStatus503DoesNotReplay() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = ApplicationStatus503Transport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run { stateObject.connectionState == .connected || stateObject.connectionState == .updating }
    }
    #expect(connected)

    do {
      _ = try await realtime.send(
        SendTestTransaction(
          id: UUID(),
          method: applicationStatus503Method,
          type: .mutation()
        )
      )
      Issue.record("Expected the application error to fail the transaction")
    } catch let error as TransactionError {
      guard case let .rpcError(rpcError) = error else {
        Issue.record("Unexpected transaction error: \(error)")
        return
      }
      #expect(rpcError.code == 503)
    }

    try await Task.sleep(for: .milliseconds(1_100))
    #expect(await transport.targetAttemptCount == 1)
    withExtendedLifetime(realtime) {}
  }

  @Test("disconnected ephemeral work fails before optimistic projection")
  func testDisconnectedEphemeralWorkFailsBeforeOptimisticProjection() async throws {
    await SendTestRecorder.shared.reset()
    let id = UUID()
    let realtime = RealtimeV2(
      transport: MockTransport(),
      auth: Auth.mocked(authenticated: true).handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    do {
      _ = try await realtime.send(
        SendTestTransaction(id: id, type: .ephemeral())
      )
      Issue.record("Expected disconnected ephemeral work to be rejected")
    } catch let error as TransactionError {
      guard case .timeout = error else {
        Issue.record("Unexpected ephemeral rejection: \(error)")
        return
      }
    }

    #expect(await SendTestRecorder.shared.didRunOptimistic(id) == false)
    #expect(await SendTestRecorder.shared.didRunApply(id) == false)
    withExtendedLifetime(realtime) {}
  }

  @Test("send runs optimistic before rpc dispatch")
  func testSendRunsOptimisticBeforeRpcDispatch() async throws {
    await SendOrderingProbe.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = OptimisticOrderingTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected || stateObject.connectionState == .updating
      }
    }
    #expect(connected)

    _ = try await realtime.send(SendOrderingTransaction(id: UUID()))
    #expect(await SendOrderingProbe.shared.didObserveRpcBeforeOptimistic() == false)

    withExtendedLifetime(realtime) {}
  }

  @Test("send fails when acked transaction cannot retry after reconnect")
  func testSendFailsWhenAckedTransactionCannotRetryAfterReconnect() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = AckThenDisconnectTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected || stateObject.connectionState == .updating
      }
    }
    #expect(connected)

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          _ = try await realtime.send(AckNoRetryTransaction(id: UUID()))
          return ()
        }
        group.addTask {
          try await Task.sleep(for: .seconds(5))
          throw SendTestTimeoutError.timedOut
        }
        _ = try await group.next()
        group.cancelAll()
      }
      Issue.record("Expected send to fail for acked non-retry transaction after reconnect")
    } catch let error as TransactionError {
      if case .commitOutcomeUnknownAfterReconnect = error {
        // expected
      } else {
        Issue.record("Unexpected TransactionError: \(error)")
      }
    } catch SendTestTimeoutError.timedOut {
      Issue.record("Timed out waiting for send failure")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    withExtendedLifetime(realtime) {}
  }

  @Test("carrier commit-unknown preserves transaction optimistic state")
  func testCarrierCommitUnknownUsesUnknownOutcomeHook() async throws {
    await UnknownOutcomeRecorder.shared.reset()
    let auth = Auth.mocked(authenticated: true)
    let realtime = RealtimeV2(
      transport: CarrierCommitUnknownTransport(),
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    #expect(await waitForCondition(timeout: .seconds(2)) {
      await MainActor.run { realtime.stateObject.connectionState == .connected || realtime.stateObject.connectionState == .updating }
    })

    do {
      _ = try await realtime.send(UnknownOutcomeTransaction(id: UUID()))
      Issue.record("Expected carrier commit-unknown transaction to fail")
    } catch let error as TransactionError {
      guard case .commitOutcomeUnknownAfterReconnect = error else {
        Issue.record("Unexpected transaction error: \(error)")
        return
      }
    }

    #expect(await UnknownOutcomeRecorder.shared.commitUnknownCount == 1)
    #expect(await UnknownOutcomeRecorder.shared.failedCount == 0)
    withExtendedLifetime(realtime) {}
  }

  @Test("queued transactions created while disconnected run after reconnect")
  func testQueuedTransactionsCreatedWhileDisconnectedRunAfterReconnect() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = DropAndRecoverTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let initiallyConnected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected || stateObject.connectionState == .updating
      }
    }
    #expect(initiallyConnected)

    await transport.simulateDisconnect()

    let becameDisconnected = await waitForCondition(timeout: .seconds(1)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState != .connected
      }
    }
    #expect(becameDisconnected)

    let transactionID = UUID()
    _ = await realtime.sendQueued(ReconnectQueueTransaction(id: transactionID))

    let reconnected = await waitForCondition(timeout: .seconds(3)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected || stateObject.connectionState == .updating
      }
    }
    #expect(reconnected)

    let appliedAfterReconnect = await waitForCondition(timeout: .seconds(1)) {
      await ReconnectQueueRecorder.shared.didRunApply(transactionID)
    }
    #expect(appliedAfterReconnect)

    withExtendedLifetime(realtime) {}
  }

  @Test("send waits for blockers before rpc dispatch")
  func testSendWaitsForBlockerSatisfaction() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = BlockedSendTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected || stateObject.connectionState == .updating
      }
    }
    #expect(connected)

    let id = UUID()
    let sendTask = Task {
      try await realtime.send(BlockedSendTransaction(id: id, chatId: 77))
    }

    let optimisticRan = await waitForCondition(timeout: .seconds(1)) {
      await SendTestRecorder.shared.didRunOptimistic(id)
    }
    #expect(optimisticRan)

    try await Task.sleep(for: .milliseconds(100))
    #expect(await transport.didDispatchBlockedMethod() == false)

    await realtime.satisfyTransactionBlockers([.chatCreated(chatId: 77)])

    let result = try await sendTask.value
    #expect(result == nil)
    #expect(await transport.didDispatchBlockedMethod())
    #expect(await SendTestRecorder.shared.didRunApply(id))

    withExtendedLifetime(realtime) {}
  }

  @Test("cancelling a dispatched send resumes promptly without claiming server cancellation")
  func testSendCancellationIsPreserved() async throws {
    await SendCancellationRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = HangingRpcTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected || stateObject.connectionState == .updating
      }
    }
    #expect(connected)

    let id = UUID()
    let sendTask = Task {
      try await realtime.send(CancellableSendTransaction(id: id))
    }

    #expect(await waitForCondition { await transport.didDispatchRpc() })
    sendTask.cancel()

    do {
      _ = try await sendTask.value
      Issue.record("Expected CancellationError")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected CancellationError, got \(error)")
    }

    let serverCancellationClaimed = await SendCancellationRecorder.shared.wasCancelled(id)
    #expect(serverCancellationClaimed == false)
    await realtime.loggedOut()
  }

  @Test("application termination waits for in-flight apply and preserves sync state")
  func testTerminationWaitsForApplyAndPreservesSyncState() async throws {
    await TerminationApplyGate.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let storage = SendTestSyncStorage()
    let realtime = RealtimeV2(
      transport: ImmediateRoundTripTransport(),
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: storage
    )

    #expect(await waitForCondition(timeout: .seconds(2)) {
      await MainActor.run { realtime.stateObject.connectionState == .connected || realtime.stateObject.connectionState == .updating }
    })

    let sendTask = Task {
      do {
        _ = try await realtime.send(TerminationBlockingTransaction())
        return false
      } catch is CancellationError {
        return true
      } catch {
        Issue.record("Expected termination cancellation, got \(error)")
        return false
      }
    }
    try #require(await waitForCondition(timeout: .seconds(3)) {
      await TerminationApplyGate.shared.hasStarted()
    })

    let terminationReturned = SendTestFlag()
    let terminationTask = Task {
      await realtime.prepareForTermination()
      await terminationReturned.set()
    }

    try await Task.sleep(for: .milliseconds(100))
    #expect(await terminationReturned.get() == false)

    await TerminationApplyGate.shared.release()
    await terminationTask.value

    #expect(await terminationReturned.get())
    #expect(await sendTask.value)
    #expect(await storage.clearCallCount() == 0)
  }

  @Test("application termination preserves persisted mutations")
  func testTerminationPreservesPersistedMutations() async throws {
    await FailingDependencyResolver.shared.reset()
    await TerminationProjectionRecorder.shared.reset()
    await FailingDependencyResolver.shared.setState(.blocked, for: .chatCreated(chatId: 77))

    let auth = Auth.mocked(authenticated: true)
    let persistence = AccountSwitchSendPersistence()
    let storage = SendTestSyncStorage()
    let realtime = RealtimeV2(
      transport: AccountSwitchSendTransport(),
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: storage,
      persistenceHandler: persistence,
      blockerResolver: FailingDependencyResolver.shared
    )

    #expect(await waitForCondition(timeout: .seconds(2)) {
      await MainActor.run { realtime.stateObject.connectionState == .connected || realtime.stateObject.connectionState == .updating }
    })

    let sendTask = Task {
      do {
        _ = try await realtime.send(TerminationPersistedTransaction(chatId: 77))
        return false
      } catch is CancellationError {
        return true
      } catch {
        Issue.record("Expected termination cancellation, got \(error)")
        return false
      }
    }
    try #require(await waitForCondition(timeout: .seconds(3)) {
      await persistence.savedOwners().isEmpty == false
    })

    await realtime.prepareForTermination()

    #expect(await sendTask.value)
    #expect(await persistence.deletedAllOwners().isEmpty)
    #expect(await TerminationProjectionRecorder.shared.wasCancelled() == false)
    #expect(await storage.clearCallCount() == 0)
  }

  @Test("application termination preserves a queued admission racing persistence")
  func testTerminationPreservesQueuedAdmissionRacingPersistence() async throws {
    await AccountSwitchSendRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let persistence = TerminationAdmissionPersistence()
    let realtime = RealtimeV2(
      transport: AccountSwitchSendTransport(),
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage(),
      persistenceHandler: persistence
    )
    let transactionID = UUID()
    let sendTask = Task {
      await realtime.sendQueuedIfAccepted(AccountSwitchSendTransaction(id: transactionID))
    }

    try #require(await waitForCondition(timeout: .seconds(3)) {
      await persistence.hasStartedSaving()
    })

    let terminationTask = Task {
      await realtime.prepareForTermination()
    }
    try? await Task.sleep(for: .milliseconds(50))
    await persistence.releaseSave()

    #expect(await sendTask.value != nil)
    await terminationTask.value
    #expect(await AccountSwitchSendRecorder.shared.cancelledCount(transactionID) == 0)
    #expect(await persistence.deletedAllOwners().isEmpty)
  }

  @Test("failed dependency wakes blocked send and fails it")
  func testFailedDependencyFailsBlockedSend() async throws {
    await FailingDependencyResolver.shared.reset()
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = DependencyFailureTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage,
      blockerResolver: FailingDependencyResolver.shared
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected || stateObject.connectionState == .updating
      }
    }
    #expect(connected)

    let chatId: Int64 = 88
    await FailingDependencyResolver.shared.setState(.blocked, for: .chatCreated(chatId: chatId))

    let sendID = UUID()
    let sendTask = Task {
      try await realtime.send(BlockedSendTransaction(id: sendID, chatId: chatId))
    }

    let optimisticRan = await waitForCondition(timeout: .seconds(1)) {
      await SendTestRecorder.shared.didRunOptimistic(sendID)
    }
    #expect(optimisticRan)

    _ = await realtime.sendQueued(FailingCreatorTransaction(chatId: chatId))

    let creatorDispatched = await waitForCondition(timeout: .seconds(1)) {
      await transport.didDispatchCreatorMethod()
    }
    #expect(creatorDispatched)

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          _ = try await sendTask.value
          return ()
        }
        group.addTask {
          try await Task.sleep(for: .seconds(2))
          throw SendTestTimeoutError.timedOut
        }
        _ = try await group.next()
        group.cancelAll()
      }
      Issue.record("Expected blocked send to fail after dependency failure")
    } catch let error as TransactionError {
      if case .dependencyFailed = error {
        #expect(await transport.didDispatchBlockedMethod() == false)
      } else {
        Issue.record("Unexpected TransactionError: \(error)")
      }
    } catch SendTestTimeoutError.timedOut {
      Issue.record("Timed out waiting for dependency failure")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    withExtendedLifetime(realtime) {}
  }

  @Test("limited RPC errors retry two times before failing")
  func testLimitedRpcErrorsRetryTwoTimesBeforeFailing() async throws {
    await LimitedRpcRetryRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = LimitedRpcErrorTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected || stateObject.connectionState == .updating
      }
    }
    #expect(connected)

    let id = UUID()
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          _ = try await realtime.send(LimitedRpcRetryTransaction(id: id))
          return ()
        }
        group.addTask {
          try await Task.sleep(for: .seconds(3))
          throw SendTestTimeoutError.timedOut
        }
        _ = try await group.next()
        group.cancelAll()
      }
      Issue.record("Expected limited RPC error transaction to fail after retries")
    } catch let error as TransactionError {
      if case let .rpcError(rpcError) = error {
        #expect(rpcError.errorCode == .peerIDInvalid)
      } else {
        Issue.record("Unexpected TransactionError: \(error)")
      }
    } catch SendTestTimeoutError.timedOut {
      Issue.record("Timed out waiting for limited RPC error retries")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(await transport.rpcDispatchCount() == 3)
    #expect(await LimitedRpcRetryRecorder.shared.didFail(id))

    withExtendedLifetime(realtime) {}
  }

  @Test("protocol session emits connectionError event")
  func testProtocolSessionEmitsConnectionErrorEvent() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    let sawConnectionError = SendTestFlag()

    await session.start()

    Task {
      for await envelope in session.events {
        if case .connectionError(reason: .unspecified) = envelope.event,
           envelope.originatingSessionID == 42 {
          await sawConnectionError.set()
          await envelope.markProcessed()
          return
        }
      }
    }

    await session.startTransport(sessionID: 42)
    await transport.emit(.message(connectionErrorMessage()))

    let received = await waitForCondition {
      await sawConnectionError.get()
    }
    #expect(received)
  }

  @Test("application UNAUTHENTICATED stays request-scoped; authenticated invalidation remains terminal")
  func testApplicationUnauthenticatedDoesNotInvalidateAccount() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = ApplicationUnauthenticatedTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: SendTestApplyUpdates(),
      syncStorage: SendTestSyncStorage()
    )
    let invalidated = SendTestFlag()
    let observer = NotificationCenter.default.addObserver(
      forName: .realtimeV2AuthInvalidated,
      object: nil,
      queue: nil
    ) { _ in
      Task { await invalidated.set() }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    let connected = await waitForCondition(timeout: .seconds(2)) {
      await transport.didOpen()
    }
    #expect(connected)

    do {
      _ = try await realtime.callRpcDirect(
        method: .createUpload,
        input: .createUpload(.init()),
        timeout: .seconds(1)
      )
      Issue.record("Expected the upload RPC to fail")
    } catch let error as RealtimeDirectRpcError {
      guard case let .rpcError(errorCode, _, code) = error else {
        Issue.record("Unexpected direct RPC error: \(error)")
        return
      }
      #expect(errorCode == .unauthenticated)
      #expect(code == 401)
    }

    do {
      _ = try await realtime.send(
        SendTestTransaction(
          id: UUID(),
          method: .createUpload,
          type: .query()
        )
      )
      Issue.record("Expected the transaction RPC to fail")
    } catch let error as TransactionError {
      guard case let .rpcError(rpcError) = error else {
        Issue.record("Unexpected transaction error: \(error)")
        return
      }
      #expect(rpcError.errorCode == .unauthenticated)
      #expect(rpcError.code == 401)
    }

    try await Task.sleep(for: .milliseconds(100))
    #expect(await invalidated.get() == false)

    await transport.emitAuthenticatedInvalidation()
    let receivedInvalidation = await waitForCondition(timeout: .seconds(1)) {
      await invalidated.get()
    }
    #expect(receivedInvalidation)
    withExtendedLifetime(realtime) {}
  }

  @Test("a session reset during direct dispatch validation prevents the old write")
  func testResetDuringDirectDispatchValidation() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    let entered = SendTestFlag()
    let gate = DirectRpcStartGate()
    let request = Task {
      try await session.callRpc(method: .sendMessage, input: nil, timeout: .seconds(2), beforeDispatch: {
        await entered.set()
        await gate.wait()
      })
    }
    let didEnter = await waitForCondition(timeout: .seconds(1)) { await entered.get() }
    #expect(didEnter)
    await session.stopTransport()
    await gate.release()
    await #expect(throws: (any Error).self) { try await request.value }
    await session.waitForDirectDispatches()
    #expect(await transport.sentMessages.isEmpty)
  }

  @Test("protocol session registers RPC ownership before transport write")
  func testProtocolSessionRegistersRPCOwnershipBeforeTransportWrite() async throws {
    let auth = Auth.mocked(authenticated: true)
    let probe = RPCPreparationProbe()
    let transport = RPCPreparationObservingTransport(probe: probe)
    let session = ProtocolSession(transport: transport, auth: auth.handle)

    let messageID = try await session.sendRpc(method: .getMe, input: nil) { messageID in
      await probe.register(messageID)
    }

    #expect(await probe.registeredMessageID() == messageID)
    #expect(await transport.observedPreparedOwnership())
  }

  @Test("protocol session does not write when RPC ownership registration fails")
  func testProtocolSessionDoesNotWriteWhenOwnershipRegistrationFails() async {
    let auth = Auth.mocked(authenticated: true)
    let transport = RPCWriteCountingTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)

    await #expect(throws: RPCPreparationTestError.self) {
      try await session.sendRpc(method: .getMe, input: nil) { _ in
        throw RPCPreparationTestError()
      }
    }

    #expect(await transport.sendCount == 0)
  }

  @Test("direct RPC completion waits for earlier account update processing")
  func testDirectRPCWaitsForEarlierAccountUpdateProcessing() async throws {
    await TerminationApplyGate.shared.reset()
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    let completed = SendTestFlag()
    await session.start()

    let collector = Task {
      for await envelope in session.events {
        if case .updates = envelope.event {
          await TerminationApplyGate.shared.hold()
        }
        await envelope.markProcessed()
      }
    }
    defer { collector.cancel() }

    let resultTask = Task {
      _ = try await session.callRpc(method: .getUpdatesState, input: nil, timeout: .seconds(1))
      await completed.set()
    }
    try #require(await waitForCondition {
      !(await transport.sentMessages.isEmpty)
    })
    let requestID = try #require(await transport.sentMessages.first?.id)

    var updatesPayload = InlineProtocol.UpdatesPayload()
    updatesPayload.updates = []
    var serverMessage = InlineProtocol.ServerMessage()
    serverMessage.payload = .update(updatesPayload)
    var updateEnvelope = ServerProtocolMessage()
    updateEnvelope.body = .message(serverMessage)
    await transport.emit(.message(updateEnvelope))

    try #require(await waitForCondition {
      await TerminationApplyGate.shared.hasStarted()
    })
    var result = InlineProtocol.RpcResult()
    result.reqMsgID = requestID
    var resultEnvelope = ServerProtocolMessage()
    resultEnvelope.body = .rpcResult(result)
    let resultDelivery = Task { await transport.emit(.message(resultEnvelope)) }

    try? await Task.sleep(for: .milliseconds(30))
    #expect(await completed.get() == false)

    await TerminationApplyGate.shared.release()
    try await resultTask.value
    await resultDelivery.value
    #expect(await completed.get())
  }

  @Test("protocol request IDs remain unique across transport reset")
  func testProtocolRequestIDsRemainUniqueAcrossTransportReset() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)

    let first = try await session.sendRpc(method: .getMe, input: nil)
    await session.stopTransport()
    let second = try await session.sendRpc(method: .getMe, input: nil)

    #expect(second > first)
  }

  @Test("late RPC results from an old transport cannot complete a new request")
  func testLateOldTransportResultCannotCollideAfterReset() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    await session.start()
    let collector = Task {
      for await envelope in session.events {
        await envelope.markProcessed()
      }
    }
    defer { collector.cancel() }

    let oldRequest = Task {
      try await session.callRpc(method: .getMe, input: nil, timeout: nil)
    }
    try #require(await waitForCondition { await transport.sentMessages.count == 1 })
    let oldID = try #require(await transport.sentMessages.first?.id)

    await session.stopTransport()
    do {
      _ = try await oldRequest.value
      Issue.record("Expected the old request to be cancelled by transport reset")
    } catch ProtocolSessionError.stopped {
      // Expected.
    } catch {
      Issue.record("Unexpected old request error: \(error)")
    }

    let newCompleted = SendTestFlag()
    let newRequest = Task {
      _ = try await session.callRpc(method: .getMe, input: nil, timeout: .seconds(1))
      await newCompleted.set()
    }
    try #require(await waitForCondition { await transport.sentMessages.count == 2 })
    let newID = try #require(await transport.sentMessages.last?.id)
    #expect(newID != oldID)

    var oldResult = InlineProtocol.RpcResult()
    oldResult.reqMsgID = oldID
    var oldEnvelope = ServerProtocolMessage()
    oldEnvelope.body = .rpcResult(oldResult)
    await transport.emit(.message(oldEnvelope))
    await transport.emit(.rpcCommitOutcomeUnknown(msgId: oldID))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await newCompleted.get() == false)

    var newResult = InlineProtocol.RpcResult()
    newResult.reqMsgID = newID
    var newEnvelope = ServerProtocolMessage()
    newEnvelope.body = .rpcResult(newResult)
    await transport.emit(.message(newEnvelope))
    _ = try await newRequest.value
    #expect(await newCompleted.get())
  }

  @Test("direct RPC timeout after transport acceptance has unknown commit outcome")
  func testDirectRPCTimeoutAfterTransportAcceptanceIsCommitUnknown() async {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)

    do {
      _ = try await session.callRpc(
        method: .deleteChat,
        input: nil,
        timeout: .milliseconds(10)
      )
      Issue.record("Expected the unanswered mutation to time out")
    } catch ProtocolSessionError.commitOutcomeUnknown {
      // Expected: the transport accepted the request, but no authoritative result arrived.
    } catch {
      Issue.record("Unexpected direct RPC error: \(error)")
    }
  }

  @Test("direct RPC drain waits for a blocked transport send after caller timeout")
  func testDirectRPCDrainWaitsForBlockedTransportSend() async throws {
    let transport = BlockingDirectDispatchTransport()
    let session = ProtocolSession(
      transport: transport,
      auth: Auth.mocked(authenticated: true).handle
    )
    let rpc = Task {
      try await session.callRpc(
        method: .deleteChat,
        input: nil,
        timeout: .milliseconds(10)
      )
    }
    try #require(await waitForCondition { await transport.isBlocked() })
    do {
      _ = try await rpc.value
      Issue.record("Expected caller timeout while transport dispatch remains blocked")
    } catch ProtocolSessionError.commitOutcomeUnknown {
      // The transport dispatch lease must nevertheless remain registered.
    }

    let drained = SendTestFlag()
    let drain = Task {
      await session.waitForDirectDispatches()
      await drained.set()
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await drained.get() == false)
    await transport.release()
    await drain.value
    #expect(await drained.get())
  }

  @Test("direct dispatch finalizes its drain lease for both pre-write transport errors")
  func testDirectRPCDrainFinalizesForTransportErrors() async {
    for transportError in [TransportError.notConnected, .capacityExceeded] {
      let transport = DirectDispatchFailureTransport(error: transportError)
      let session = ProtocolSession(
        transport: transport,
        auth: Auth.mocked(authenticated: true).handle
      )
      do {
        _ = try await session.callRpc(method: .deleteChat, input: nil, timeout: .seconds(1))
        Issue.record("Expected direct dispatch transport error")
      } catch ProtocolSessionError.notConnected where transportError == .notConnected {
        // Known-unsent and fully drained.
      } catch ProtocolSessionError.capacityExceeded where transportError == .capacityExceeded {
        // Known-unsent and fully drained.
      } catch {
        Issue.record("Unexpected direct dispatch error: \(error)")
      }
      await session.waitForDirectDispatches()
      #expect(await transport.sendCount() == 1)
    }
  }

  @Test("direct RPC admission rejects request 65 without a transport write")
  func testDirectRPCCapacityRejectsBeforeWrite() async throws {
    let transport = MockTransport()
    let session = ProtocolSession(
      transport: transport,
      auth: Auth.mocked(authenticated: true).handle
    )
    let pending = (0 ..< 64).map { _ in
      Task {
        try await session.callRpc(method: .getMe, input: nil, timeout: nil)
      }
    }
    defer { pending.forEach { $0.cancel() } }

    let capacityFilled = await waitForCondition(timeout: .seconds(2)) {
      await transport.sentMessages.count == 64
    }
    guard capacityFilled else {
      Issue.record("Expected 64 direct requests to fill the direct-RPC owner")
      return
    }

    do {
      _ = try await session.callRpc(method: .getMe, input: nil, timeout: nil)
      Issue.record("Expected direct request 65 to be rejected")
    } catch ProtocolSessionError.capacityExceeded {
      // Local admission failed before transport ownership or request bytes.
    } catch {
      Issue.record("Unexpected direct capacity error: \(error)")
    }
    #expect(await transport.sentMessages.count == 64)
  }

  @Test("direct RPC cancellation after dispatch reports unknown outcome without stranding capacity")
  func testDirectRPCCancellationReleasesPendingOwnership() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    await session.start()
    let collector = Task {
      for await envelope in session.events {
        await envelope.markProcessed()
      }
    }
    defer { collector.cancel() }

    let cancelled = Task {
      try await session.callRpc(method: .deleteChat, input: nil, timeout: nil)
    }
    try #require(await waitForCondition {
      await transport.sentMessages.count == 1
    })
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      Issue.record("Expected direct RPC cancellation")
    } catch ProtocolSessionError.commitOutcomeUnknown {
      // Cancellation after the dispatch boundary stops waiting without claiming
      // that server execution stopped.
    } catch {
      Issue.record("Unexpected direct RPC cancellation error: \(error)")
    }

    let next = Task {
      try await session.callRpc(method: .getMe, input: nil, timeout: .seconds(1))
    }
    try #require(await waitForCondition {
      await transport.sentMessages.count == 2
    })
    let nextID = try #require(await transport.sentMessages.last?.id)
    var result = InlineProtocol.RpcResult()
    result.reqMsgID = nextID
    var envelope = ServerProtocolMessage()
    envelope.body = .rpcResult(result)
    await transport.emit(.message(envelope))
    _ = try await next.value
  }

  @Test("direct read-only RPC cancellation after dispatch remains cancellation")
  func testDirectReadOnlyRPCCancellationAfterDispatchRemainsCancellation() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)

    let cancelled = Task {
      try await session.callRpc(method: .getMe, input: nil, timeout: nil)
    }
    try #require(await waitForCondition {
      await transport.sentMessages.count == 1
    })
    cancelled.cancel()

    do {
      _ = try await cancelled.value
      Issue.record("Expected direct read-only RPC cancellation")
    } catch is CancellationError {
      // Cancellation stops interest in a query result and cannot hide a mutation.
    } catch {
      Issue.record("Unexpected direct read-only RPC cancellation error: \(error)")
    }
  }

  @Test("direct RPC cancellation before admission does not write")
  func testDirectRPCCancellationBeforeAdmissionDoesNotWrite() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    let gate = DirectRpcStartGate()
    let cancelled = Task {
      await gate.wait()
      _ = try await session.callRpc(method: .deleteChat, input: nil, timeout: nil)
    }

    cancelled.cancel()
    await gate.release()

    do {
      _ = try await cancelled.value
      Issue.record("Expected direct RPC cancellation before admission")
    } catch is CancellationError {
      // The request never crossed the dispatch boundary.
    } catch {
      Issue.record("Unexpected direct RPC cancellation error: \(error)")
    }
    #expect(await transport.sentMessages.isEmpty)
  }

  @Test("carrier commit-unknown completes only the matching direct RPC")
  func testCarrierCommitUnknownStaysRequestScoped() async {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    await session.start()
    let collector = Task {
      for await envelope in session.events {
        await envelope.markProcessed()
      }
    }
    defer { collector.cancel() }

    let resultTask = Task { () -> Bool in
      do {
        _ = try await session.callRpc(method: .deleteChat, input: nil, timeout: .seconds(1))
        return false
      } catch ProtocolSessionError.commitOutcomeUnknown {
        return true
      } catch {
        return false
      }
    }

    let sent = await waitForCondition {
      !(await transport.sentMessages.isEmpty)
    }
    #expect(sent)
    if let messageID = await transport.sentMessages.first?.id {
      await transport.emit(.rpcCommitOutcomeUnknown(msgId: messageID))
    }
    #expect(await resultTask.value)
  }

  @Test("carrier pre-execution rejection is a known-unsent direct failure")
  func testCarrierPreexecutionRejectionStaysRequestScoped() async {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    await session.start()
    let collector = Task {
      for await envelope in session.events {
        await envelope.markProcessed()
      }
    }
    defer { collector.cancel() }

    let resultTask = Task { () -> Bool in
      do {
        _ = try await session.callRpc(method: .deleteChat, input: nil, timeout: .seconds(1))
        return false
      } catch ProtocolSessionError.capacityExceeded {
        return true
      } catch {
        return false
      }
    }

    let sent = await waitForCondition {
      !(await transport.sentMessages.isEmpty)
    }
    #expect(sent)
    if let messageID = await transport.sentMessages.first?.id {
      await transport.emit(.rpcRejectedBeforeExecution(msgId: messageID))
    }
    #expect(await resultTask.value)
  }

  @Test("connectionError posts restart alert notification when auth refresh shows missing token")
  func testConnectionErrorPostsRestartAlertNotificationWhenTokenMissing() async throws {
    let authDriver = AuthSnapshotDriver(
      AuthSnapshot(
        status: .authenticated(AuthCredentials(userId: 1, token: "1:initialToken")),
        didHydrate: true
      )
    )
    let auth = makeTestAuthHandle(snapshotDriver: authDriver)
    let transport = MockTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth,
      applyUpdates: apply,
      syncStorage: storage
    )

    let didPostNotification = SendTestFlag()
    let observer = NotificationCenter.default.addObserver(
      forName: .realtimeV2ConnectionInitFailed,
      object: nil,
      queue: nil
    ) { _ in
      Task {
        await didPostNotification.set()
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    authDriver.set(
      AuthSnapshot(
        status: .reauthRequired(userIdHint: 1),
        didHydrate: true
      )
    )

    try? await Task.sleep(for: .milliseconds(50))
    await transport.emit(.message(connectionErrorMessage()))

    let notified = await waitForCondition(timeout: .seconds(1)) {
      await didPostNotification.get()
    }
    #expect(notified)

    withExtendedLifetime(realtime) {}
  }
}

private actor RPCPreparationProbe {
  private var messageID: UInt64?

  func register(_ messageID: UInt64) {
    self.messageID = messageID
  }

  func registeredMessageID() -> UInt64? {
    messageID
  }
}

private actor DirectRpcStartGate {
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?

  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation in
      waiter = continuation
    }
  }

  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

private actor RPCPreparationObservingTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private let probe: RPCPreparationProbe
  private var ownershipWasPrepared = false

  init(probe: RPCPreparationProbe) {
    self.probe = probe
  }

  func start() async {}
  func stop() async {}

  func send(_ message: ClientMessage) async throws {
    ownershipWasPrepared = await probe.registeredMessageID() == message.id
  }

  func observedPreparedOwnership() -> Bool {
    ownershipWasPrepared
  }
}

private struct RPCPreparationTestError: Error {}

private actor RPCWriteCountingTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()
  private(set) var sendCount = 0

  func start() async {}
  func stop() async {}
  func send(_: ClientMessage) async throws { sendCount += 1 }
}

private actor AccountSwitchSendRecorder {
  static let shared = AccountSwitchSendRecorder()

  private var optimistic: [UUID: Int] = [:]
  private var cancelled: [UUID: Int] = [:]
  private var applied: [UUID: Int] = [:]
  private var failed: [UUID: Int] = [:]
  private var optimisticAction: (@Sendable () async -> Void)?

  func reset(optimisticAction: (@Sendable () async -> Void)? = nil) {
    optimistic.removeAll()
    cancelled.removeAll()
    applied.removeAll()
    failed.removeAll()
    self.optimisticAction = optimisticAction
  }

  func runOptimistic(_ id: UUID) async {
    optimistic[id, default: 0] += 1
    await optimisticAction?()
  }

  func markCancelled(_ id: UUID) {
    cancelled[id, default: 0] += 1
  }

  func markApplied(_ id: UUID) {
    applied[id, default: 0] += 1
  }

  func markFailed(_ id: UUID) {
    failed[id, default: 0] += 1
  }

  func optimisticCount(_ id: UUID) -> Int { optimistic[id, default: 0] }
  func cancelledCount(_ id: UUID) -> Int { cancelled[id, default: 0] }
  func applyCount(_ id: UUID) -> Int { applied[id, default: 0] }
  func failedCount(_ id: UUID) -> Int { failed[id, default: 0] }
}

private actor UnknownOutcomeRecorder {
  static let shared = UnknownOutcomeRecorder()

  private(set) var commitUnknownCount = 0
  private(set) var failedCount = 0

  func reset() {
    commitUnknownCount = 0
    failedCount = 0
  }

  func markCommitUnknown() {
    commitUnknownCount += 1
  }

  func markFailed() {
    failedCount += 1
  }
}

private struct UnknownOutcomeTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = carrierCommitUnknownMethod
  var type: TransactionKindType = .mutation()
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? { nil }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}

  func failed(error: TransactionError) async {
    await UnknownOutcomeRecorder.shared.markFailed()
  }

  func commitOutcomeUnknown() async {
    await UnknownOutcomeRecorder.shared.markCommitUnknown()
  }
}

private actor CarrierCommitUnknownTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private let channel = AsyncChannel<TransportEvent>()
  private var started = false

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await channel.send(.message(open))
    case let .rpcCall(call) where call.method == carrierCommitUnknownMethod:
      await channel.send(.rpcCommitOutcomeUnknown(msgId: message.id))
    default:
      break
    }
  }
}

private struct AccountSwitchSendTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = accountSwitchSendMethod
  var type: TransactionKindType = .mutation()
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? { nil }

  func optimistic() async {
    await AccountSwitchSendRecorder.shared.runOptimistic(context.id)
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    await AccountSwitchSendRecorder.shared.markApplied(context.id)
  }

  func failed(error: TransactionError) async {
    await AccountSwitchSendRecorder.shared.markFailed(context.id)
  }

  func cancelled() async {
    await AccountSwitchSendRecorder.shared.markCancelled(context.id)
  }
}

private actor AccountSwitchSendPersistence: TransactionPersistenceHandler {
  private var owners: [TransactionOwner] = []
  private var deletedOwners: [TransactionOwner] = []

  func saveTransaction(_ transaction: TransactionWrapper, for owner: TransactionOwner) async throws {
    owners.append(owner)
  }

  func deleteTransaction(_ transactionId: TransactionId, for owner: TransactionOwner) async throws {}
  func loadTransactions(for owner: TransactionOwner) async throws -> [TransactionWrapper] { [] }
  func deleteAllTransactions(for owner: TransactionOwner) async throws {
    deletedOwners.append(owner)
  }

  func savedOwners() -> [TransactionOwner] {
    owners
  }

  func deletedAllOwners() -> [TransactionOwner] {
    deletedOwners
  }
}

private actor TerminationAdmissionPersistence: TransactionPersistenceHandler {
  private var startedSaving = false
  private var saveWasReleased = false
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var deletedOwners: [TransactionOwner] = []

  func saveTransaction(_ transaction: TransactionWrapper, for owner: TransactionOwner) async throws {
    startedSaving = true
    await withCheckedContinuation { continuation in
      if saveWasReleased {
        continuation.resume()
      } else {
        releaseWaiters.append(continuation)
      }
    }
  }

  func deleteTransaction(_ transactionId: TransactionId, for owner: TransactionOwner) async throws {}
  func loadTransactions(for owner: TransactionOwner) async throws -> [TransactionWrapper] { [] }
  func deleteAllTransactions(for owner: TransactionOwner) async throws {
    deletedOwners.append(owner)
  }

  func hasStartedSaving() -> Bool { startedSaving }

  func releaseSave() {
    saveWasReleased = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func deletedAllOwners() -> [TransactionOwner] { deletedOwners }
}

private actor FailingAccountSwitchSendPersistence: TransactionPersistenceHandler {
  struct SaveFailure: Error {}

  func saveTransaction(_ transaction: TransactionWrapper, for owner: TransactionOwner) async throws {
    throw SaveFailure()
  }

  func deleteTransaction(_ transactionId: TransactionId, for owner: TransactionOwner) async throws {}
  func loadTransactions(for owner: TransactionOwner) async throws -> [TransactionWrapper] { [] }
  func deleteAllTransactions(for owner: TransactionOwner) async throws {}
}

private actor AccountSwitchSendTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private let channel = AsyncChannel<TransportEvent>()
  private var started = false
  private var dispatchedAccountSwitchMutation = false

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await channel.send(.message(open))

    case let .rpcCall(call):
      guard call.method == accountSwitchSendMethod else { return }
      dispatchedAccountSwitchMutation = true

      var result = InlineProtocol.RpcResult()
      result.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(result)
      await channel.send(.message(response))

    default:
      break
    }
  }

  func didDispatchAccountSwitchMutation() -> Bool {
    dispatchedAccountSwitchMutation
  }
}

private struct SendTestTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = .UNRECOGNIZED(0)
  var type: TransactionKindType = .query()
  var context: Context

  init(
    id: UUID,
    method: InlineProtocol.Method = .UNRECOGNIZED(0),
    type: TransactionKindType = .query()
  ) {
    context = Context(id: id)
    self.method = method
    self.type = type
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func optimistic() async {
    await SendTestRecorder.shared.markOptimistic(context.id)
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    await SendTestRecorder.shared.markApply(context.id)
  }
}

private struct RejectedOptimisticStateTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {}

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = .UNRECOGNIZED(9_999_976)
  var type: TransactionKindType = .mutation()
  var context = Context()

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? { nil }

  func optimistic() async {
    await OptimisticValidationRecorder.shared.markOptimistic()
  }

  func validateOptimisticState() async -> Bool { false }

  func cancelled() async {
    await OptimisticValidationRecorder.shared.markCancelled()
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

private actor OptimisticValidationRecorder {
  static let shared = OptimisticValidationRecorder()

  private var optimistic = 0
  private var cancelled = 0

  func reset() {
    optimistic = 0
    cancelled = 0
  }

  func markOptimistic() {
    optimistic += 1
  }

  func markCancelled() {
    cancelled += 1
  }

  func optimisticCount() -> Int { optimistic }
  func cancelledCount() -> Int { cancelled }
}

private actor SendTestRecorder {
  static let shared = SendTestRecorder()

  private var optimistic: Set<UUID> = []
  private var applied: Set<UUID> = []

  func reset() {
    optimistic.removeAll()
    applied.removeAll()
  }

  func markOptimistic(_ id: UUID) {
    optimistic.insert(id)
  }

  func markApply(_ id: UUID) {
    applied.insert(id)
  }

  func didRunOptimistic(_ id: UUID) -> Bool {
    optimistic.contains(id)
  }

  func didRunApply(_ id: UUID) -> Bool {
    applied.contains(id)
  }
}

private actor SendTestFlag {
  private var value = false

  func set() {
    value = true
  }

  func get() -> Bool {
    value
  }
}

private actor ApplicationUnauthenticatedTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private let channel = AsyncChannel<TransportEvent>()
  private var started = false
  private var opened = false

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    opened = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      opened = true
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .connectionOpen(.init())
      await channel.send(.message(response))
    case let .rpcCall(call) where call.method == .createUpload:
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcError(.with {
        $0.reqMsgID = message.id
        $0.errorCode = .unauthenticated
        $0.message = "Unauthenticated"
        $0.code = 401
      })
      await channel.send(.message(response))
    default:
      break
    }
  }

  func didOpen() -> Bool { opened }

  func emitAuthenticatedInvalidation() async {
    await channel.send(.message(connectionErrorMessage(reason: .invalidAuth)))
  }
}

private let terminationBlockingMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_977)
private let terminationPersistedMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_978)

private actor TerminationProjectionRecorder {
  static let shared = TerminationProjectionRecorder()

  private var cancelled = false

  func reset() {
    cancelled = false
  }

  func markCancelled() {
    cancelled = true
  }

  func wasCancelled() -> Bool {
    cancelled
  }
}

private actor TerminationApplyGate {
  static let shared = TerminationApplyGate()

  private var started = false
  private var waiter: CheckedContinuation<Void, Never>?

  func reset() {
    started = false
    waiter = nil
  }

  func hold() async {
    started = true
    await withCheckedContinuation { continuation in
      waiter = continuation
    }
  }

  func hasStarted() -> Bool {
    started
  }

  func release() {
    waiter?.resume()
    waiter = nil
  }
}

private struct TerminationBlockingTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {}

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = terminationBlockingMethod
  var type: TransactionKindType = .query()
  var context = Context()

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? { nil }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    await TerminationApplyGate.shared.hold()
  }
}

private struct TerminationPersistedTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let chatId: Int64
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = terminationPersistedMethod
  var type: TransactionKindType = .mutation()
  var context: Context

  init(chatId: Int64) {
    context = Context(chatId: chatId)
  }

  var blockers: [TransactionBlocker] {
    [.chatCreated(chatId: context.chatId)]
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? { nil }
  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}

  func cancelled() async {
    await TerminationProjectionRecorder.shared.markCancelled()
  }
}

private actor SendCancellationRecorder {
  static let shared = SendCancellationRecorder()
  private var cancelled: Set<UUID> = []

  func reset() {
    cancelled.removeAll()
  }

  func markCancelled(_ id: UUID) {
    cancelled.insert(id)
  }

  func wasCancelled(_ id: UUID) -> Bool {
    cancelled.contains(id)
  }
}

private struct CancellableSendTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = cancellableSendMethod
  var type: TransactionKindType = .query()
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? { nil }
  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}

  func cancelled() async {
    await SendCancellationRecorder.shared.markCancelled(context.id)
  }
}

private actor HangingRpcTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private let channel = AsyncChannel<TransportEvent>()
  private var started = false
  private var dispatchedRpc = false

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
      case .connectionInit:
        var open = ServerProtocolMessage()
        open.id = message.id
        open.body = .connectionOpen(.init())
        await channel.send(.message(open))
      case let .rpcCall(call):
        if call.method == cancellableSendMethod {
          dispatchedRpc = true
        }
      default:
        break
    }
  }

  func didDispatchRpc() -> Bool {
    dispatchedRpc
  }
}

private actor BlockingDirectDispatchTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private var blocked = false
  private var continuation: CheckedContinuation<Void, Never>?

  func start() async {}
  func stop() async {}

  func send(_ message: ClientMessage) async throws {
    guard case .rpcCall = message.body else { return }
    blocked = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func isBlocked() -> Bool { blocked }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor DirectDispatchFailureTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private let error: TransportError
  private var count = 0

  init(error: TransportError) {
    self.error = error
  }

  func start() async {}
  func stop() async {}

  func send(_ message: ClientMessage) async throws {
    guard case .rpcCall = message.body else { return }
    count += 1
    throw error
  }

  func sendCount() -> Int { count }
}

private final class AuthSnapshotDriver: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshot: AuthSnapshot

  init(_ initialSnapshot: AuthSnapshot) {
    snapshot = initialSnapshot
  }

  func get() -> AuthSnapshot {
    lock.withLock { snapshot }
  }

  func set(_ nextSnapshot: AuthSnapshot) {
    lock.withLock { snapshot = nextSnapshot }
  }
}

private func makeTestAuthHandle(snapshotDriver: AuthSnapshotDriver) -> AuthHandle {
  let cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
  let store = AuthStore(
    cache: cache,
    mocked: true,
    namespace: UUID().uuidString,
    readSnapshot: { _, _, _ in snapshotDriver.get() }
  )
  return AuthHandle(cache: cache, store: store)
}

private actor ImmediateRoundTripTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private var started = false
  private let channel = AsyncChannel<TransportEvent>()

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await channel.send(.message(open))

    case .rpcCall:
      var rpcResult = InlineProtocol.RpcResult()
      rpcResult.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(rpcResult)
      await channel.send(.message(response))

    default:
      break
    }
  }
}

private actor HeldResultTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private var started = false
  private var pendingMessages: [ClientMessage] = []

  var pendingMultiplexedResultCount: Int {
    pendingMessages.count { message in
      guard case let .rpcCall(call) = message.body else { return false }
      return call.method == multiplexedSendMethod
    }
  }

  func start() async {
    guard !started else { return }
    started = true
    await events.send(.connecting)
    await events.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await events.send(.message(open))
    case .rpcCall:
      pendingMessages.append(message)
    default:
      break
    }
  }

  func completePendingResultsInReverseOrder() async {
    let messages = pendingMessages.reversed()
    pendingMessages.removeAll()
    for message in messages {
      var result = InlineProtocol.RpcResult()
      result.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(result)
      await events.send(.message(response))
    }
  }

  func completePendingResults(limit: Int) async {
    var messages: [ClientMessage] = []
    var remaining: [ClientMessage] = []
    for message in pendingMessages {
      let isMultiplexed = if case let .rpcCall(call) = message.body {
        call.method == multiplexedSendMethod
      } else {
        false
      }
      if isMultiplexed, messages.count < max(0, limit) {
        messages.append(message)
      } else {
        remaining.append(message)
      }
    }
    pendingMessages = remaining
    for message in messages {
      var result = InlineProtocol.RpcResult()
      result.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(result)
      await events.send(.message(response))
    }
  }
}

private actor FailOnceTransactionTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private var started = false
  private(set) var targetAttemptCount = 0

  func start() async {
    guard !started else { return }
    started = true
    await events.send(.connecting)
    await events.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await events.send(.message(open))
    case let .rpcCall(call):
      if call.method == deferredSpinMethod {
        targetAttemptCount += 1
        if targetAttemptCount == 1 { throw TransportError.notConnected }
      }
      var result = InlineProtocol.RpcResult()
      result.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(result)
      await events.send(.message(response))
    default:
      break
    }
  }
}

private actor PreWriteNotConnectedTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private var started = false
  private(set) var targetAttemptCount = 0

  func start() async {
    guard !started else { return }
    started = true
    await events.send(.connecting)
    await events.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await events.send(.message(open))
    case let .rpcCall(call):
      guard call.method == preWriteMutationMethod else { return }
      targetAttemptCount += 1
      if targetAttemptCount == 1 {
        // Model the real transport guard: no request bytes were accepted.
        throw TransportError.notConnected
      }
      var result = InlineProtocol.RpcResult()
      result.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(result)
      await events.send(.message(response))
    default:
      break
    }
  }
}

private actor PreWriteCapacityTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private var started = false
  private(set) var targetAttemptCount = 0

  func start() async {
    guard !started else { return }
    started = true
    await events.send(.connecting)
    await events.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await events.send(.message(open))
    case let .rpcCall(call):
      guard call.method == preWriteCapacityMethod else { return }
      targetAttemptCount += 1
      if targetAttemptCount == 1 {
        // The carrier did not accept this record, so mutation outcome is known-unsent.
        throw TransportError.capacityExceeded
      }
      var result = InlineProtocol.RpcResult()
      result.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(result)
      await events.send(.message(response))
    default:
      break
    }
  }
}

private actor RejectedBeforeExecutionTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private var started = false
  private(set) var targetAttemptCount = 0

  func start() async {
    guard !started else { return }
    started = true
    await events.send(.connecting)
    await events.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await events.send(.message(open))
    case let .rpcCall(call):
      guard call.method == rejectedBeforeExecutionMethod else { return }
      targetAttemptCount += 1
      if targetAttemptCount == 1 {
        await events.send(.rpcRejectedBeforeExecution(msgId: message.id))
      } else {
        var response = ServerProtocolMessage()
        response.id = message.id
        response.body = .rpcResult(.with { $0.reqMsgID = message.id })
        await events.send(.message(response))
      }
    default:
      break
    }
  }
}

private actor ApplicationStatus503Transport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private var started = false
  private(set) var targetAttemptCount = 0

  func start() async {
    guard !started else { return }
    started = true
    await events.send(.connecting)
    await events.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await events.send(.message(open))
    case let .rpcCall(call):
      guard call.method == applicationStatus503Method else { return }
      targetAttemptCount += 1
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcError(.with {
        $0.reqMsgID = message.id
        $0.errorCode = .internalError
        $0.code = 503
        $0.message = "application unavailable"
      })
      await events.send(.message(response))
    default:
      break
    }
  }
}

private actor SendOrderingProbe {
  static let shared = SendOrderingProbe()

  private var optimisticRan = false
  private var rpcDispatchedBeforeOptimistic = false

  func reset() {
    optimisticRan = false
    rpcDispatchedBeforeOptimistic = false
  }

  func markOptimisticRan() {
    optimisticRan = true
  }

  func markRpcDispatched() {
    if !optimisticRan {
      rpcDispatchedBeforeOptimistic = true
    }
  }

  func didObserveRpcBeforeOptimistic() -> Bool {
    rpcDispatchedBeforeOptimistic
  }
}

private struct SendOrderingTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = sendOrderingMethod
  var type: TransactionKindType = .query()
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func optimistic() async {
    await SendOrderingProbe.shared.markOptimisticRan()
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

private actor OptimisticOrderingTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private var started = false
  private let channel = AsyncChannel<TransportEvent>()

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await channel.send(.message(open))

    case let .rpcCall(rpcCall):
      if rpcCall.method == sendOrderingMethod {
        await SendOrderingProbe.shared.markRpcDispatched()
      }

      var rpcResult = InlineProtocol.RpcResult()
      rpcResult.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(rpcResult)
      await channel.send(.message(response))

    default:
      break
    }
  }
}

private let sendOrderingMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_991)
private let blockedSendMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_992)
private let failingCreatorMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_993)
private let limitedRpcRetryMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_994)
private let accountSwitchSendMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_995)
private let multiplexedSendMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_996)
private let deferredSpinMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_997)
private let preWriteMutationMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_998)
private let carrierCommitUnknownMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_999)
private let preWriteCapacityMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_990)
private let rejectedBeforeExecutionMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_989)
private let applicationStatus503Method: InlineProtocol.Method = .UNRECOGNIZED(9_999_988)
private let cancellableSendMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_979)

private struct BlockedSendTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
    let chatId: Int64
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = blockedSendMethod
  var type: TransactionKindType = .query()
  var context: Context

  init(id: UUID, chatId: Int64) {
    context = Context(id: id, chatId: chatId)
  }

  var blockers: [TransactionBlocker] {
    [.chatCreated(chatId: context.chatId)]
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func optimistic() async {
    await SendTestRecorder.shared.markOptimistic(context.id)
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    await SendTestRecorder.shared.markApply(context.id)
  }
}

private actor BlockedSendTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private var started = false
  private var blockedMethodDispatched = false
  private let channel = AsyncChannel<TransportEvent>()

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
      case .connectionInit:
        var open = ServerProtocolMessage()
        open.id = message.id
        open.body = .connectionOpen(.init())
        await channel.send(.message(open))

      case let .rpcCall(rpcCall):
        if rpcCall.method == blockedSendMethod {
          blockedMethodDispatched = true
        }

        var rpcResult = InlineProtocol.RpcResult()
        rpcResult.reqMsgID = message.id
        var response = ServerProtocolMessage()
        response.id = message.id
        response.body = .rpcResult(rpcResult)
        await channel.send(.message(response))

      default:
        break
    }
  }

  func didDispatchBlockedMethod() -> Bool {
    blockedMethodDispatched
  }
}

private actor FailingDependencyResolver: TransactionBlockerResolver {
  static let shared = FailingDependencyResolver()

  private var states: [TransactionBlocker: TransactionBlockerState] = [:]

  func reset() {
    states.removeAll()
  }

  func setState(_ state: TransactionBlockerState, for blocker: TransactionBlocker) {
    states[blocker] = state
  }

  func state(for blocker: TransactionBlocker) async -> TransactionBlockerState {
    states[blocker] ?? .blocked
  }
}

private struct FailingCreatorTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let chatId: Int64
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = failingCreatorMethod
  var type: TransactionKindType = .mutation()
  var context: Context

  init(chatId: Int64) {
    context = Context(chatId: chatId)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}

  func failed(error: TransactionError) async {
    try? await Task.sleep(for: .milliseconds(150))
    await FailingDependencyResolver.shared.setState(.failed, for: .chatCreated(chatId: context.chatId))
  }
}

private actor DependencyFailureTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private var started = false
  private var creatorMethodDispatched = false
  private var blockedMethodDispatched = false
  private let channel = AsyncChannel<TransportEvent>()

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
      case .connectionInit:
        var open = ServerProtocolMessage()
        open.id = message.id
        open.body = .connectionOpen(.init())
        await channel.send(.message(open))

      case let .rpcCall(rpcCall):
        if rpcCall.method == failingCreatorMethod {
          creatorMethodDispatched = true

          var rpcError = InlineProtocol.RpcError()
          rpcError.reqMsgID = message.id
          rpcError.errorCode = .badRequest
          rpcError.message = "failed creator"
          rpcError.code = 400

          var response = ServerProtocolMessage()
          response.id = message.id
          response.body = .rpcError(rpcError)
          await channel.send(.message(response))
        } else if rpcCall.method == blockedSendMethod {
          blockedMethodDispatched = true

          var rpcResult = InlineProtocol.RpcResult()
          rpcResult.reqMsgID = message.id
          var response = ServerProtocolMessage()
          response.id = message.id
          response.body = .rpcResult(rpcResult)
          await channel.send(.message(response))
        } else if rpcCall.method == .getUpdatesState {
          var result = InlineProtocol.GetUpdatesStateResult()
          result.date = Int64(Date().timeIntervalSince1970)
          result.seq = 0

          var rpcResult = InlineProtocol.RpcResult()
          rpcResult.reqMsgID = message.id
          rpcResult.result = .getUpdatesState(result)

          var response = ServerProtocolMessage()
          response.id = message.id
          response.body = .rpcResult(rpcResult)
          await channel.send(.message(response))
        } else if rpcCall.method == .getUpdates {
          var result = InlineProtocol.GetUpdatesResult()
          result.seq = 0
          result.date = Int64(Date().timeIntervalSince1970)
          result.final = true
          result.resultType = .empty

          var rpcResult = InlineProtocol.RpcResult()
          rpcResult.reqMsgID = message.id
          rpcResult.result = .getUpdates(result)

          var response = ServerProtocolMessage()
          response.id = message.id
          response.body = .rpcResult(rpcResult)
          await channel.send(.message(response))
        }

      default:
        break
    }
  }

  func didDispatchCreatorMethod() -> Bool {
    creatorMethodDispatched
  }

  func didDispatchBlockedMethod() -> Bool {
    blockedMethodDispatched
  }
}

private actor LimitedRpcRetryRecorder {
  static let shared = LimitedRpcRetryRecorder()

  private var failed: Set<UUID> = []

  func reset() {
    failed.removeAll()
  }

  func markFailed(_ id: UUID) {
    failed.insert(id)
  }

  func didFail(_ id: UUID) -> Bool {
    failed.contains(id)
  }
}

private struct LimitedRpcRetryTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = limitedRpcRetryMethod
  var type: TransactionKindType = .query()
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}

  func failed(error: TransactionError) async {
    await LimitedRpcRetryRecorder.shared.markFailed(context.id)
  }
}

private actor LimitedRpcErrorTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private var started = false
  private var dispatchCount = 0
  private let channel = AsyncChannel<TransportEvent>()

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
      case .connectionInit:
        var open = ServerProtocolMessage()
        open.id = message.id
        open.body = .connectionOpen(.init())
        await channel.send(.message(open))

      case let .rpcCall(rpcCall):
        guard rpcCall.method == limitedRpcRetryMethod else { return }

        dispatchCount += 1
        var rpcError = InlineProtocol.RpcError()
        rpcError.reqMsgID = message.id
        rpcError.errorCode = .peerIDInvalid
        rpcError.message = "peer invalid"
        rpcError.code = 400

        var response = ServerProtocolMessage()
        response.id = message.id
        response.body = .rpcError(rpcError)
        await channel.send(.message(response))

      default:
        break
    }
  }

  func rpcDispatchCount() -> Int {
    dispatchCount
  }
}

private struct ReconnectQueueTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = reconnectQueueMethod
  var type: TransactionKindType = .query()
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    await ReconnectQueueRecorder.shared.markApply(context.id)
  }
}

private actor ReconnectQueueRecorder {
  static let shared = ReconnectQueueRecorder()
  private var applied: Set<UUID> = []

  func markApply(_ id: UUID) {
    applied.insert(id)
  }

  func didRunApply(_ id: UUID) -> Bool {
    applied.contains(id)
  }
}

private struct AckNoRetryTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = ackNoRetryMethod
  var type: TransactionKindType = .mutation(MutationConfig())
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

private actor AckThenDisconnectTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private var started = false
  private var didAckAndDisconnectTargetRpc = false
  private let channel = AsyncChannel<TransportEvent>()

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await channel.send(.message(open))

    case let .rpcCall(rpcCall):
      if rpcCall.method == ackNoRetryMethod && !didAckAndDisconnectTargetRpc {
        didAckAndDisconnectTargetRpc = true

        var ack = ServerProtocolMessage()
        ack.id = message.id
        ack.body = .ack(.with {
          $0.msgID = message.id
        })
        await channel.send(.message(ack))
        try? await Task.sleep(for: .milliseconds(500))

        started = false
        await channel.send(.disconnected(errorDescription: "simulated_disconnect_after_ack"))
      } else {
        var rpcResult = InlineProtocol.RpcResult()
        rpcResult.reqMsgID = message.id
        var response = ServerProtocolMessage()
        response.id = message.id
        response.body = .rpcResult(rpcResult)
        await channel.send(.message(response))
      }

    default:
      break
    }
  }
}

private actor DropAndRecoverTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private var started = false
  private let channel = AsyncChannel<TransportEvent>()

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await channel.send(.message(open))

    case .rpcCall:
      var rpcResult = InlineProtocol.RpcResult()
      rpcResult.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(rpcResult)
      await channel.send(.message(response))

    default:
      break
    }
  }

  func simulateDisconnect() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "simulated_disconnect"))
  }
}

private let ackNoRetryMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_992)
private let reconnectQueueMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_993)

private enum SendTestTimeoutError: Error {
  case timedOut
}

private actor SendTestApplyUpdates: ApplyUpdates {
  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    .success(count: updates.count)
  }
}

private actor ImmediateUpdateApplyRecorder: ApplyUpdates {
  private(set) var count = 0

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    count += updates.count
    return .success(count: updates.count)
  }
}

private actor ImmediateOpenUpdateTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()
  private var started = false

  func start() async {
    guard !started else { return }
    started = true
    await events.send(.connecting)
    await events.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    guard case .connectionInit = message.body else { return }

    var open = ServerProtocolMessage()
    open.id = message.id
    open.body = .connectionOpen(.init())
    await events.send(.message(open))

    var status = InlineProtocol.UpdateUserStatus()
    status.userID = 1
    var userStatus = InlineProtocol.UserStatus()
    userStatus.online = .online
    status.status = userStatus
    var update = InlineProtocol.Update()
    update.update = .updateUserStatus(status)
    var payload = InlineProtocol.UpdatesPayload()
    payload.updates = [update]
    var serverMessage = InlineProtocol.ServerMessage()
    serverMessage.payload = .update(payload)
    var updateEnvelope = ServerProtocolMessage()
    updateEnvelope.body = .message(serverMessage)
    await events.send(.message(updateEnvelope))
  }
}

private actor SendTestSyncStorage: SyncStorage {
  private var state = SyncState(lastSyncDate: 0)
  private var bucketStates: [BucketKey: BucketState] = [:]
  private var clearCount = 0

  func getState() async -> SyncState {
    state
  }

  @discardableResult
  func setState(_ state: SyncState) async -> Bool {
    self.state = state
    return true
  }

  func getBucketState(for key: BucketKey) async -> BucketState {
    bucketStates[key] ?? BucketState(date: 0, seq: 0)
  }

  @discardableResult
  func setBucketState(for key: BucketKey, state: BucketState) async -> Bool {
    bucketStates[key] = state
    return true
  }

  func advanceBucketState(for key: BucketKey, state: BucketState) async -> BucketState? {
    if let existing = bucketStates[key], existing.seq > state.seq {
      return existing
    }
    let effective = BucketState(
      date: max(bucketStates[key]?.date ?? 0, state.date),
      seq: state.seq
    )
    bucketStates[key] = effective
    return effective
  }

  @discardableResult
  func removeBucketState(for key: BucketKey) async -> Bool {
    bucketStates.removeValue(forKey: key)
    return true
  }

  @discardableResult
  func setBucketStates(states: [BucketKey: BucketState]) async -> Bool {
    for (key, state) in states {
      if let existing = bucketStates[key], existing.seq > state.seq {
        continue
      }
      bucketStates[key] = BucketState(
        date: max(bucketStates[key]?.date ?? 0, state.date),
        seq: state.seq
      )
    }
    return true
  }

  @discardableResult
  func clearSyncState() async -> Bool {
    clearCount += 1
    state = SyncState(lastSyncDate: 0)
    bucketStates.removeAll()
    return true
  }

  func clearCallCount() -> Int {
    clearCount
  }
}

private func connectionErrorMessage(reason: ConnectionError.Reason = .unspecified) -> ServerProtocolMessage {
  var message = ServerProtocolMessage()
  message.id = 1
  message.body = .connectionError(.with {
    $0.reason = reason
  })
  return message
}

private func waitForCondition(
  timeout: Duration = .seconds(1),
  pollInterval: Duration = .milliseconds(10),
  _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while await condition() == false {
    if clock.now >= deadline {
      return false
    }
    try? await clock.sleep(for: pollInterval)
  }

  return true
}

private actor DelayedOnboardingTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()
  private(set) var started = false
  private(set) var profileCalls = 0
  private var connected = false

  func isApplicationAuthenticatedOnConnect() async -> Bool { true }
  func start() async {
    guard !started else { return }
    started = true
    await events.send(.connecting)
  }
  func allowConnection() async {
    connected = true
    await events.send(.connected)
  }
  func stop() async {
    connected = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }
  func send(_ message: ClientMessage) async throws {
    guard connected else { throw TransportError.notConnected }
    guard case let .rpcCall(call) = message.body, call.method == .updateProfile else { return }
    profileCalls += 1
    var result = InlineProtocol.RpcResult()
    result.reqMsgID = message.id
    result.result = .updateProfile(.with { $0.user = .with { $0.id = 1; $0.firstName = "Test" } })
    var response = ServerProtocolMessage()
    response.body = .rpcResult(result)
    await events.send(.message(response))
  }
}
