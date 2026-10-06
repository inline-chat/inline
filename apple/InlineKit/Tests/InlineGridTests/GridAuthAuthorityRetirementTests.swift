import Foundation
import InlineProtocol
import Testing

@testable import Auth
@testable import InlineGrid
@testable import InlineRTC

@Suite("Grid auth authority retirement", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct GridAuthAuthorityRetirementTests {
  enum ReplacementKind: CaseIterable, Sendable, Equatable {
    case explicitNative, implicitNative, changedBearer
  }

  @Test("same-account replacement waits for physical retirement before writing or publishing",
        arguments: ReplacementKind.allCases)
  func replacementWaitsForPhysicalRetirement(kind: ReplacementKind) async throws {
    let fixture = GridAuthorityTestFixture()
    do {
      if kind == .changedBearer {
        try await fixture.store.saveCredentials(token: "1:original", userId: 1)
      } else {
        try await fixture.seedAccount()
      }
      let oldAccount = try fixture.auth.beginAccountMutation()
      try await fixture.admit()
      fixture.service.toggleMicrophone(spaceID: 42)
      try await eventuallyGridAuthority {
        let recording = await fixture.audio.runtimeHealth().isRecording
        let muted = await fixture.rtc.microphoneMuted
        return recording && !muted
      }
      await fixture.audio.blockShutdown()
      let previousWrites = fixture.writes.value
      let attempt = kind == .explicitNative
        ? try await fixture.auth.beginLoginAttempt(allowAuthenticated: true) : nil
      let replacement = Task {
        if kind == .changedBearer {
          try await fixture.store.saveCredentials(token: "1:replacement", userId: 1)
        } else {
          try await fixture.auth.saveInlineProtocolCredentials(
            fixture.credentials(sessionID: 11), loginAttempt: attempt
          )
        }
        if let attempt { return try await fixture.auth.finalizeCredentialsCommittedByLoginAttempt(attempt) }
        return try fixture.auth.beginAccountMutation()
      }
      try await eventuallyGridAuthority { await fixture.audio.shutdownCalls > 0 }
      #expect(!fixture.service.hasLocalAdmission)
      #expect(fixture.service.mediaSessionIdentity == nil)
      #expect(fixture.writes.value == previousWrites)
      if kind == .changedBearer {
        #expect(fixture.auth.token() == "1:original")
      } else {
        #expect(fixture.auth.inlineProtocolCredentials()?.accountSessionId == 10)
      }
      #expect(fixture.auth.hasPendingAccountTransition())
      await fixture.audio.releaseShutdown(succeeded: true)
      let newAccount = try await replacement.value
      #expect(newAccount.userID == oldAccount.userID)
      #expect((newAccount != oldAccount) == (kind == .explicitNative))
      #expect(fixture.writes.value == previousWrites + 1)
      if kind == .changedBearer {
        #expect(fixture.auth.token() == "1:replacement")
      } else {
        #expect(fixture.auth.inlineProtocolCredentials()?.accountSessionId == 11)
      }
      #expect(!(await fixture.audio.runtimeHealth().isRecording))
      #expect(!fixture.service.hasLocalAdmission)
      if kind == .explicitNative {
        #expect((try? fixture.auth.validateAccountMutation(oldAccount)) == nil)
      } else {
        try fixture.auth.validateAccountMutation(oldAccount)
      }
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("a failed local retirement rejects replacement and preserves prior authority without media readmission",
        arguments: ReplacementKind.allCases)
  func failedRetirementDoesNotWriteAuthority(kind: ReplacementKind) async throws {
    let fixture = GridAuthorityTestFixture()
    do {
      if kind == .changedBearer {
        try await fixture.store.saveCredentials(token: "1:original", userId: 1)
      } else {
        try await fixture.seedAccount()
      }
      let oldAccount = try fixture.auth.beginAccountMutation()
      try await fixture.admit()
      await fixture.audio.blockShutdown()
      let previousWrites = fixture.writes.value
      let attempt = kind == .explicitNative
        ? try await fixture.auth.beginLoginAttempt(allowAuthenticated: true) : nil
      let replacement = Task {
        if kind == .changedBearer {
          try await fixture.store.saveCredentials(token: "1:replacement", userId: 1)
        } else {
          try await fixture.auth.saveInlineProtocolCredentials(
            fixture.credentials(sessionID: 11), loginAttempt: attempt
          )
        }
      }
      try await eventuallyGridAuthority { await fixture.audio.shutdownCalls > 0 }
      await fixture.audio.releaseShutdown(succeeded: false)
      await #expect(throws: AuthStorageError.loginUnavailable) { try await replacement.value }
      #expect(fixture.writes.value == previousWrites)
      if kind == .changedBearer {
        #expect(fixture.auth.token() == "1:original")
      } else {
        #expect(fixture.auth.inlineProtocolCredentials()?.accountSessionId == 10)
      }
      #expect(!fixture.auth.hasPendingAccountTransition())
      try fixture.auth.validateAccountMutation(oldAccount)
      #expect(!fixture.service.hasLocalAdmission)
      #expect(fixture.service.mediaSessionIdentity == nil)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  enum UnchangedKind: CaseIterable, Sendable, Equatable { case temporaryKey, identicalBearer }

  @Test("temporary native renewal and identical implicit bearer keep the admitted call uninterrupted",
        arguments: UnchangedKind.allCases)
  func unchangedAuthorityDoesNotRetire(kind: UnchangedKind) async throws {
    let fixture = GridAuthorityTestFixture()
    do {
      if kind == .identicalBearer {
        try await fixture.store.saveCredentials(token: "1:original", userId: 1)
      } else {
        try await fixture.seedAccount()
      }
      let account = try fixture.auth.beginAccountMutation()
      try await fixture.admit()
      let identity = fixture.service.mediaSessionIdentity
      let shutdownCalls = await fixture.audio.shutdownCalls
      let oldWrites = fixture.writes.value
      await fixture.audio.blockShutdown()
      let renewal = Task {
        if kind == .identicalBearer {
          try await fixture.store.saveCredentials(token: "1:original", userId: 1)
        } else {
          var credentials = try fixture.credentials(sessionID: 10)
          let key = Array((UInt8.min...UInt8.max).reversed())
          credentials.temporary = try InlineProtocolAuthorization(
            key: key, keyID: InlineSecureTransport.authKeyID(key), serverSalt: 8,
            temporary: true, expiresAt: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)
          )
          try await fixture.auth.saveInlineProtocolCredentials(credentials)
        }
      }
      try await eventuallyGridAuthority {
        kind == .temporaryKey
          ? fixture.auth.inlineProtocolCredentials()?.temporary != nil
          : fixture.writes.value == oldWrites + 1
      }
      try await renewal.value
      try fixture.auth.validateAccountMutation(account)
      #expect(fixture.service.hasLocalAdmission)
      #expect(fixture.service.mediaSessionIdentity == identity)
      #expect(await fixture.audio.shutdownCalls == shutdownCalls)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("replacement waits for prior retirement even after Leave cleared admission")
  func replacementWaitsAfterAdmissionCleared() async throws {
    let fixture = GridAuthorityTestFixture()
    do {
      try await fixture.seedAccount()
      try await fixture.admit()
      await fixture.audio.blockShutdown()
      let leaving = fixture.service.withdrawLocalAdmission()
      #expect(!fixture.service.hasLocalAdmission)
      let previousWrites = fixture.writes.value
      let attempt = try await fixture.auth.beginLoginAttempt(allowAuthenticated: true)
      let replacement = Task {
        try await fixture.auth.saveInlineProtocolCredentials(
          fixture.credentials(sessionID: 11), loginAttempt: attempt
        )
        return try await fixture.auth.finalizeCredentialsCommittedByLoginAttempt(attempt)
      }
      try await eventuallyGridAuthority {
        await fixture.audio.shutdownCalls > 0 && fixture.auth.hasPendingAccountTransition()
      }
      #expect(fixture.writes.value == previousWrites)
      await fixture.audio.releaseShutdown(succeeded: true)
      #expect(await leaving.value.isLocallyQuiescent)
      _ = try await replacement.value
      #expect(fixture.writes.value == previousWrites + 1)
      #expect(!fixture.service.hasLocalAdmission)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("replaying a completed authority request cannot retire a successor admission")
  func staleAuthorityRequestCannotRetireSuccessor() async throws {
    let fixture = GridAuthorityTestFixture()
    var request: AuthAccountAuthorityRetirement?
    let observation = fixture.auth.observeAccountAuthorityWillChange { request = $0 }
    defer { NotificationCenter.default.removeObserver(observation) }
    do {
      try await fixture.seedAccount()
      try await fixture.admit()
      let attempt = try await fixture.auth.beginLoginAttempt(allowAuthenticated: true)
      try await fixture.auth.saveInlineProtocolCredentials(fixture.credentials(sessionID: 11), loginAttempt: attempt)
      _ = try await fixture.auth.finalizeCredentialsCommittedByLoginAttempt(attempt)
      let oldRequest = try #require(request)
      #expect(!oldRequest.isCurrent)
      try await fixture.admit(membershipID: "membership-b", intentRevision: 1)
      let connectedIdentity = fixture.service.mediaSessionIdentity
      let shutdownCalls = await fixture.audio.shutdownCalls
      NotificationCenter.default.post(
        name: .authAccountAuthorityWillChange, object: fixture.cache,
        userInfo: ["retirement": oldRequest]
      )
      #expect(fixture.service.hasLocalAdmission)
      #expect(fixture.service.mediaSessionIdentity == connectedIdentity)
      #expect(fixture.service.currentCall?.membershipID == "membership-b")
      #expect(await fixture.audio.shutdownCalls == shutdownCalls)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("receipt submission precedes successor demand while engine startup is suspended")
  func receiptDoesNotEnqueueBehindSuccessor() async throws {
    let audio = GridAuthorityAudioDriver(configurationBlocked: true)
    let rtc = GridAuthorityRTCDriver()
    let engine = InlineRTCSession(
      audioDriver: audio, permissionDriver: GridAuthorityPermission(), rtcDriver: rtc,
      captureCooldown: .zero
    )
    let oldRetirement = engine.requestShutdownReceipt()
    let target = InlineRTCSessionID("grid-test:1:7:3")
    engine.setDemand(InlineRTCDemand(
      target: target,
      credentials: .init(
        target: target, serverURL: URL(string: "wss://grid.invalid")!, participantIdentity: "successor",
        token: "fixture-only", expiresAt: Date().addingTimeInterval(120)
      ),
      microphoneEnabled: false, microphoneCapturePrepared: false
    ))
    try await eventuallyGridAuthority { await audio.configurationCalls > 0 }
    await audio.allowConfiguration()
    #expect(await oldRetirement.value.isLocallyQuiescent)
    try await eventuallyGridAuthority { await rtc.connectedIdentities == ["successor"] }
    let snapshots = await engine.subscribe()
    var iterator = snapshots.makeAsyncIterator()
    var connected = false
    while let snapshot = await iterator.next() {
      if snapshot.rtc.state == .connected(target) { connected = true; break }
    }
    #expect(connected)
    #expect(await engine.shutdown().isLocallyQuiescent)
  }

  @Test("unfinished and rejected mailbox shutdown commands return unproven receipts")
  func unfinishedReceiptFailsClosed() async {
    let mailbox = GridEngineCommandMailbox()
    let queued = GridShutdownCompletion()
    mailbox.enqueue(.shutdown(requestID: UUID(), completion: queued))
    mailbox.finish()
    #expect(!(await queued.value().isLocallyQuiescent))
    let rejected = GridShutdownCompletion()
    mailbox.enqueue(.shutdown(requestID: UUID(), completion: rejected))
    #expect(!(await rejected.value().isLocallyQuiescent))
  }
}
