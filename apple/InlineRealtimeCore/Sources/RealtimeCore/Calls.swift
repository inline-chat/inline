public struct CallID: Hashable, Sendable {
  public let rawValue: Int64
  public init(_ rawValue: Int64) { self.rawValue = rawValue }
}
/// Non-durable, never automatically replayed. The optional deadline includes
/// offline and capacity waits, unlike a per-attempt network timeout.
public struct Call<Payload: Equatable & Sendable>: Equatable, Sendable {
  public let id: CallID
  public let payload: Payload
  public let expiresAt: Tick?
  public init(id: CallID, payload: Payload, expiresAt: Tick? = nil) {
    self.id = id
    self.payload = payload
    self.expiresAt = expiresAt
  }
}
public enum CallOutcome<Payload: Equatable & Sendable>: Equatable, Sendable {
  case result(Payload)
  case cancelled, expired, failed
}
struct QueuedCall<Payload: Equatable & Sendable>: Sendable {
  let id: CallID?
  let payload: Payload
  let expiresAt: Tick?
}
extension RealtimeCore {
  mutating func enqueue(_ call: Call<Payload>) {
    guard active, session != .rejected, directQueue.count < configuration.maxQueuedCalls,
      !directQueue.contains(where: { $0.id == call.id }),
      !requests.values.contains(where: {
        if case .directCall(let id, _) = $0.owner { id == call.id } else { false }
      })
    else {
      output.append(.event(.callRejected(call.id)))
      return
    }
    if let deadline = call.expiresAt, deadline <= now {
      output.append(.event(.callFinished(call.id, .expired)))
    } else {
      directQueue.append(QueuedCall(id: call.id, payload: call.payload, expiresAt: call.expiresAt))
    }
  }
  mutating func cancelCall(_ id: CallID) {
    if let index = directQueue.firstIndex(where: { $0.id == id }) {
      directQueue.remove(at: index)
      output.append(.event(.callFinished(id, .cancelled)))
      return
    }
    if let request = requests.values.first(where: {
      if case .directCall(let key, _) = $0.owner { key == id } else { false }
    }) {
      requests.removeValue(forKey: request.id)
      output.append(.cancel(request.id))
      output.append(.event(.callFinished(id, .cancelled)))
    }
  }
  mutating func expireQueuedCalls() {
    var retained: [QueuedCall<Payload>] = []
    for call in directQueue {
      if let id = call.id, let deadline = call.expiresAt, deadline <= now {
        output.append(.event(.callFinished(id, .expired)))
      } else {
        retained.append(call)
      }
    }
    directQueue = retained
  }
}
