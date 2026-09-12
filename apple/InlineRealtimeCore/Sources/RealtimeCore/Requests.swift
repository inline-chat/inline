enum RequestOwner: Equatable, Sendable {
  case bootstrap(BootstrapRequest)
  case transaction(TransactionID)
  case bucket(BucketID, from: SyncPosition, target: Int64, admission: BucketAdmission?)
  case captureLatest(BucketID, from: SyncPosition, latest: UInt64, minimum: Int64)
  case repair(BucketID)
  case discovery
  case direct
  case directCall(CallID, expiresAt: Tick?)
}
struct PendingRequest<Payload: Equatable & Sendable>: Sendable {
  let id: OperationID
  let owner: RequestOwner
  let request: Request<Payload>
  let deadline: Tick
}
struct PendingDatabase<Payload: Equatable & Sendable>: Sendable {
  let work: DatabaseWork<Payload>
  var retryAt: Tick?
}

enum AdmissionClass: CaseIterable, Sendable { case transaction, sync, direct }

extension RealtimeCore {
  mutating func transmit(_ request: Request<Payload>, owner: RequestOwner, expiresAt: Tick? = nil)
    -> OperationID
  {
    let attempt = id()
    guard let connection = session.openConnection else {
      preconditionFailure("dispatch without accepted session")
    }
    sending.insert(attempt)
    requests[attempt] = PendingRequest(
      id: attempt, owner: owner, request: request,
      deadline: min(now + configuration.requestTimeout, expiresAt ?? Int64.max))
    output.append(.transmit(attempt, connection: connection, request))
    return attempt
  }

  mutating func requestFailed(_ request: PendingRequest<Payload>, uncertain: Bool) {
    switch request.owner {
    case .bootstrap(let owner):
      bootstrap?.pending.removeValue(forKey: owner)
      bootstrap?.retryAt[owner] = now + configuration.retryDelay
    case .transaction(let key):
      guard let transaction = transactions[key] else { return }
      if uncertain && transaction.spec.replay == .neverReplay {
        settle(key, .executionUnknown)
      } else if transaction.cancellationRequested {
        settle(key, uncertain ? .executionUnknown : .cancelled)
      } else {
        transactions[key]?.phase = .ready
        transactions[key]?.retryAt = now + configuration.retryDelay
      }
    case .bucket(let key, _, _, _), .captureLatest(let key, _, _, _), .repair(let key):
      retrySync(key, reason: .requestFailed)
    case .discovery:
      discovery?.pending = nil
      discovery?.retryAt = now + configuration.retryDelay
    case .directCall(let id, let deadline):
      output.append(
        .event(.callFinished(id, deadline.map { $0 <= now } == true ? .expired : .failed)))
    case .direct:
      // Direct callers get a distinct per-attempt ticket from transmit.
      output.append(.event(.directFinished(request.id, nil)))
    }
  }
}
