enum RequestOwner: Equatable, Sendable {
  case transaction(TransactionID)
  case bucket(BucketID, from: SyncPosition, target: Int64)
  case captureLatest(BucketID, latest: UInt64, minimum: Int64)
  case repair(BucketID)
  case discovery
  case direct
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
  mutating func transmit(_ request: Request<Payload>, owner: RequestOwner) -> OperationID {
    let attempt = id()
    guard let connection = session.openConnection else {
      preconditionFailure("dispatch without accepted session")
    }
    sending.insert(attempt)
    requests[attempt] = PendingRequest(
      id: attempt, owner: owner, request: request, deadline: now + configuration.requestTimeout)
    output.append(.transmit(attempt, connection: connection, request))
    return attempt
  }

  mutating func requestFailed(_ request: PendingRequest<Payload>, uncertain: Bool) {
    switch request.owner {
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
    case .bucket(let key, _, _), .captureLatest(let key, _, _), .repair(let key):
      buckets[key]?.pending = nil
      buckets[key]?.retryAt = now + configuration.retryDelay
    case .discovery:
      discovery?.pending = nil
      discovery?.retryAt = now + configuration.retryDelay
    case .direct:
      // Direct callers get a distinct per-attempt ticket from transmit.
      output.append(.event(.directFinished(request.id, nil)))
    }
  }
}
