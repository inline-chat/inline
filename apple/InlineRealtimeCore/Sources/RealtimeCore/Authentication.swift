/// Opaque references to key material owned by the external credential store.
/// Neither secrets nor an AuthHandle enter replayable engine state.
public struct CredentialHandle: Equatable, Sendable {
  public let value: UInt64
  public init(_ value: UInt64) { self.value = value }
}
public struct TemporaryAuthorization: Equatable, Sendable {
  public let handle: CredentialHandle
  /// Monotonic deadline derived from authenticated expiry information by the adapter.
  public let rotateAt: Tick
  public init(handle: CredentialHandle, rotateAt: Tick) {
    self.handle = handle
    self.rotateAt = rotateAt
  }
}
public struct StoredCredentials: Equatable, Sendable {
  public let permanent: CredentialHandle
  public let temporary: TemporaryAuthorization?
  public init(permanent: CredentialHandle, temporary: TemporaryAuthorization?) {
    self.permanent = permanent
    self.temporary = temporary
  }
}
public enum CredentialWork: Equatable, Sendable {
  case load
  case verify(TemporaryAuthorization)
  /// One cryptographic create/bind operation. No retry or application RPC admission inside it.
  case createTemporary(permanent: CredentialHandle)
  case save(TemporaryAuthorization)
}
public enum CredentialResult: Equatable, Sendable {
  case loaded(StoredCredentials?)
  case created(TemporaryAuthorization)
  case verified
  case saved
  case temporaryRejected
  case accountRevoked
  case transientFailure
  case storageFailure
}
struct PendingCredential: Sendable {
  let connection: OperationID
  let work: CredentialWork
}
struct Authentication: Sendable {
  enum Phase: Sendable {
    case loading
    case verifying(TemporaryAuthorization, replacement: Bool)
    case creating
    case saving(TemporaryAuthorization)
    case retrySave(TemporaryAuthorization, at: Tick)
    case accepted(TemporaryAuthorization)
  }
  let connection: OperationID
  var phase: Phase = .loading
  var stored: StoredCredentials?
  var pending: OperationID?
  var replaced = false

  var deadline: Tick? {
    switch phase {
    case .accepted(let temporary): temporary.rotateAt
    case .retrySave(_, let at): at
    default: nil
    }
  }
}

extension RealtimeCore {
  mutating func beginAuthorization(_ connection: OperationID) {
    authentication = Authentication(connection: connection)
    credential(.load)
  }
  mutating func credential(_ work: CredentialWork) {
    guard let auth = authentication else { return }
    let operation = id()
    credentialOperations[operation] = PendingCredential(connection: auth.connection, work: work)
    authentication?.pending = operation
    output.append(.credentials(operation, connection: auth.connection, work))
  }
  mutating func replaceTemporary() {
    guard let auth = authentication, let stored = auth.stored, !auth.replaced else {
      rejectAuthorization()
      return
    }
    authentication?.replaced = true
    authentication?.phase = .creating
    credential(.createTemporary(permanent: stored.permanent))
  }
  mutating func rejectAuthorization() {
    if let connection = session.connection { disconnect(connection) }
    for call in directQueue {
      if let id = call.id { output.append(.event(.callFinished(id, .failed))) }
    }
    directQueue = []
    session = .rejected
    output.append(.event(.authorizationRejected))
  }
  mutating func acceptAuthorization(_ temporary: TemporaryAuthorization) {
    guard let auth = authentication, temporary.rotateAt > now else {
      if let connection = authentication?.connection { disconnect(connection) }
      return
    }
    authentication?.phase = .accepted(temporary)
    session = .open(auth.connection)
    output.append(.event(.online))
  }
  mutating func credentialsFinished(_ operation: OperationID, _ result: CredentialResult) {
    guard let pending = credentialOperations.removeValue(forKey: operation) else { return }
    guard active, operation.generation == generation,
      let auth = authentication, auth.connection == pending.connection,
      auth.pending == operation, session.connection == auth.connection
    else { return }
    authentication?.pending = nil
    switch (pending.work, result) {
    case (_, .accountRevoked): rejectAuthorization()
    case (.save(let temporary), .storageFailure), (.save(let temporary), .transientFailure):
      // Keep the verified candidate; failed local persistence does not justify another key.
      authentication?.phase = .retrySave(temporary, at: now + configuration.retryDelay)
    case (_, .transientFailure), (_, .storageFailure): disconnect(auth.connection)
    case (.load, .loaded(let stored)):
      guard let stored else {
        rejectAuthorization()
        return
      }
      authentication?.stored = stored
      if let temporary = stored.temporary, temporary.rotateAt > now {
        authentication?.phase = .verifying(temporary, replacement: false)
        credential(.verify(temporary))
      } else {
        replaceTemporary()
      }
    case (.verify(let temporary), .verified):
      guard temporary.rotateAt > now else {
        replaceTemporary()
        return
      }
      if auth.replaced {
        authentication?.phase = .saving(temporary)
        credential(.save(temporary))
      } else {
        acceptAuthorization(temporary)
      }
    case (.verify, .temporaryRejected): replaceTemporary()
    case (.createTemporary, .created(let temporary)):
      guard temporary.rotateAt > now else {
        rejectAuthorization()
        return
      }
      authentication?.phase = .verifying(temporary, replacement: true)
      credential(.verify(temporary))
    case (.save(let temporary), .saved): acceptAuthorization(temporary)
    default:
      // Mismatched completion cannot bypass verification or storage.
      credentialOperations[operation] = pending
      authentication?.pending = operation
      output.append(.event(.blocked("credential result does not match issued work")))
    }
  }
  mutating func pumpAuthorization() {
    guard let auth = authentication, case .retrySave(let temporary, let at) = auth.phase,
      at <= now
    else { return }
    authentication?.phase = .saving(temporary)
    credential(.save(temporary))
  }
  mutating func cancelAuthorization() {
    if let auth = authentication, let pending = auth.pending {
      output.append(.cancel(pending))
    }
    authentication = nil
    // Issued operations stay in the resource ledger until their completion arrives.
  }
}
