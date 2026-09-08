import Testing

@testable import RealtimeCore

let savedTemporary = TemporaryAuthorization(handle: CredentialHandle(2), rotateAt: 1_000)
let replacementTemporary = TemporaryAuthorization(handle: CredentialHandle(3), rotateAt: 2_000)

func credentialWork(_ actions: [Action]) -> [CredentialWork] {
  actions.compactMap { if case .credentials(_, _, let work) = $0 { work } else { nil } }
}
extension Scenario {
  mutating func beginAuth(_ temporary: TemporaryAuthorization? = savedTemporary) throws -> (
    OperationID, OperationID
  ) {
    let start = send(.start(generation: 1))
    let connection = try #require(
      start.compactMap { if case .connect(let id) = $0 { id } else { nil } }.first)
    let load = try credentialOperation(send(.connected(connection)))
    let next = send(
      .credentialsFinished(
        load, .loaded(StoredCredentials(permanent: CredentialHandle(1), temporary: temporary))))
    return (connection, try credentialOperation(next))
  }
}

@Suite struct AuthenticationTests {
  @Test func savedTemporaryMustBeVerifiedBeforeQueuedWorkCanDispatch() throws {
    var s = Scenario()
    let (_, verify) = try s.beginAuth()
    #expect(dbWork(try s.queue(1)).isEmpty)
    #expect(s.core.outstandingRequests == 0)
    let admitted = s.send(.credentialsFinished(verify, .verified))
    #expect(admitted.contains(.event(.online)))
    #expect(dbWork(admitted) == [.markDispatching(TransactionID(1))])
  }

  @Test func replacementMustBeVerifiedAndStoredBeforeOnline() throws {
    var s = Scenario()
    let (_, verify) = try s.beginAuth()
    let create = s.send(.credentialsFinished(verify, .temporaryRejected))
    #expect(credentialWork(create) == [.createTemporary(permanent: CredentialHandle(1))])
    let verifyNew = s.send(
      .credentialsFinished(try credentialOperation(create), .created(replacementTemporary)))
    #expect(credentialWork(verifyNew) == [.verify(replacementTemporary)])
    let save = s.send(.credentialsFinished(try credentialOperation(verifyNew), .verified))
    #expect(credentialWork(save) == [.save(replacementTemporary)])
    #expect(!s.trace.contains(.event(.online)))
    #expect(
      s.send(.credentialsFinished(try credentialOperation(save), .saved)).contains(.event(.online)))
  }

  @Test func storageFailureRetainsVerifiedCandidateAndUsesNewOperationIdentity() throws {
    var s = Scenario()
    let (_, create) = try s.beginAuth(nil)
    let verify = try credentialOperation(
      s.send(.credentialsFinished(create, .created(replacementTemporary))))
    let save = try credentialOperation(s.send(.credentialsFinished(verify, .verified)))
    s.send(.credentialsFinished(save, .storageFailure))
    #expect(!s.send(.credentialsFinished(save, .saved)).contains(.event(.online)))
    let retry = s.send(.timeout, at: 10)
    #expect(credentialWork(retry) == [.save(replacementTemporary)])
    let retryID = try credentialOperation(retry)
    #expect(retryID != save)
    #expect(s.send(.credentialsFinished(retryID, .saved)).contains(.event(.online)))
  }

  @Test func transientVerificationFailureDoesNotReplaceStoredKey() throws {
    var s = Scenario()
    let (_, verify) = try s.beginAuth()
    let failed = s.send(.credentialsFinished(verify, .transientFailure))
    #expect(credentialWork(failed).isEmpty)
    #expect(!failed.contains(.event(.authorizationRejected)))
    #expect(s.core.nextDeadline == 10)
  }

  @Test func secondTemporaryRejectionDoesNotRegenerateForever() throws {
    var s = Scenario()
    let (_, verify) = try s.beginAuth()
    let create = try credentialOperation(s.send(.credentialsFinished(verify, .temporaryRejected)))
    let retry = try credentialOperation(
      s.send(.credentialsFinished(create, .created(replacementTemporary))))
    let rejected = s.send(.credentialsFinished(retry, .temporaryRejected))
    #expect(rejected.contains(.event(.authorizationRejected)))
    #expect(credentialWork(rejected).isEmpty)
    #expect(s.core.nextDeadline == nil)
  }

  @Test func expiredSavedKeyNeverVerifiesOrCarriesApplicationTraffic() throws {
    var s = Scenario()
    let expired = TemporaryAuthorization(handle: CredentialHandle(2), rotateAt: 0)
    let (_, create) = try s.beginAuth(expired)
    #expect(
      s.core.credentialOperations[create]?.work == .createTemporary(permanent: CredentialHandle(1)))
    #expect(transmissions(try s.queue(1)).isEmpty)
  }

  @Test func rotationDeadlineGatesDispatchBeforeTimeoutCallback() throws {
    var s = Scenario()
    let (connection, verify) = try s.beginAuth()
    s.send(.credentialsFinished(verify, .verified))
    let marker = try operation(s.queue(1))
    let atExpiry = s.send(.databaseFinished(marker, .done), at: 1_000)
    #expect(atExpiry.contains(.close(connection)))
    #expect(transmissions(atExpiry).isEmpty)
    #expect(s.core.nextDeadline == 1_010)
  }

  @Test func lateVerificationCannotOpenExpiredHandshake() throws {
    var s = Scenario()
    let (_, verify) = try s.beginAuth()
    let late = s.send(.credentialsFinished(verify, .verified), at: 101)
    #expect(!late.contains(.event(.online)))
    #expect(s.core.nextDeadline == 111)
  }

  @Test func incorrectResultCannotBypassVerification() throws {
    var s = Scenario()
    let (_, verify) = try s.beginAuth()
    #expect(!s.send(.credentialsFinished(verify, .saved)).contains(.event(.online)))
    #expect(s.send(.credentialsFinished(verify, .verified)).contains(.event(.online)))
  }

  @Test func stopWaitsForCredentialOperationToActuallyEnd() throws {
    var s = Scenario()
    let (connection, verify) = try s.beginAuth()
    #expect(s.send(.stop).contains(.cancel(verify)))
    #expect(!s.send(.disconnected(connection)).contains(.event(.drained)))
    let finished = s.send(.credentialsFinished(verify, .verified))
    #expect(finished.contains(.event(.drained)))
    #expect(!finished.contains(.event(.online)))
  }

  @Test(arguments: 0..<6)
  func credentialCompletionAccountReplacementAndCloseOrders(_ index: Int) throws {
    var s = Scenario()
    let (oldConnection, oldVerify) = try s.beginAuth()
    try s.open(generation: 2)
    for event in permutations([0, 1, 2])[index] {
      switch event {
      case 0: #expect(!s.send(.credentialsFinished(oldVerify, .verified)).contains(.event(.online)))
      case 1: s.send(.disconnected(oldConnection))
      default:
        #expect(
          !s.send(.credentialsFinished(oldVerify, .accountRevoked)).contains(
            .event(.authorizationRejected)))
      }
    }
    #expect(s.core.session.openConnection?.generation == 2)
  }
}
