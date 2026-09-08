enum Session: Equatable, Sendable {
  case stopped
  case connecting(OperationID, deadline: Tick)
  case authorizing(OperationID, deadline: Tick)
  case open(OperationID)
  case backingOff(until: Tick)
  case rejected

  var connection: OperationID? {
    switch self {
    case .connecting(let id, _), .authorizing(let id, _), .open(let id): id
    default: nil
    }
  }
  var deadline: Tick? {
    switch self {
    case .connecting(_, let time), .authorizing(_, let time), .backingOff(let time): time
    default: nil
    }
  }
  var openConnection: OperationID? { if case .open(let id) = self { id } else { nil } }
}

extension RealtimeCore {
  mutating func connect() {
    let connection = id()
    session = .connecting(connection, deadline: now + configuration.requestTimeout)
    output.append(.connect(connection))
  }

  mutating func disconnect(_ connection: OperationID, alreadyClosed: Bool = false) {
    cancelAuthorization()
    if !alreadyClosed {
      closing.insert(connection)
      output.append(.close(connection))
    }
    session = .backingOff(until: now + configuration.retryDelay)
    for attempt in requests.keys.sorted(by: { $0.serial < $1.serial }) {
      if let request = requests.removeValue(forKey: attempt) {
        output.append(.cancel(attempt))
        requestFailed(request, uncertain: true)
      }
    }
  }
}
