import Testing

@testable import RealtimeCore

typealias Core = RealtimeCore<String>
typealias Action = Output<String>
typealias Tx = Transaction<String>

/// Ledger/virtual clock only. No client, database implementation, async code or sync algorithm.
struct Scenario {
  var core: Core
  var now: Tick = 0
  var trace: [Action] = []
  init(capacity: Int = 2, buffer: Int = 64) {
    core = Core(configuration: Configuration(capacity: capacity, maxBufferedUpdates: buffer))
  }
  @discardableResult
  mutating func send(_ input: Input<String>, at time: Tick? = nil) -> [Action] {
    if let time { now = time }
    let actions = core.handle(input, at: now)
    trace += actions
    #expect(core.outstandingRequests <= core.configuration.capacity)
    #expect(core.nextDeadline.map { $0 > now } ?? true, "No unexplained zero-time wake: \(actions)")
    return actions
  }
  @discardableResult
  mutating func open(generation: UInt64 = 1) throws -> OperationID {
    let started = send(.start(generation: generation))
    let connection = try #require(
      started.compactMap { if case .connect(let id) = $0 { id } else { nil } }.first)
    #expect(try authorize(connection).contains(.event(.online)))
    return connection
  }
  mutating func authorize(_ connection: OperationID) throws -> [Action] {
    let load = try credentialOperation(send(.connected(connection)))
    let verify = try credentialOperation(
      send(
        .credentialsFinished(
          load,
          .loaded(
            StoredCredentials(
              permanent: CredentialHandle(1),
              temporary: TemporaryAuthorization(handle: CredentialHandle(2), rotateAt: 1_000_000)
            )))))
    return send(.credentialsFinished(verify, .verified))
  }
  mutating func queue(
    _ id: Int64, replay: ReplayPolicy = .neverReplay, lane: String? = nil,
    requires: Set<TransactionID> = []
  ) throws -> [Action] {
    let spec = Tx(
      id: TransactionID(id), payload: "message-\(id)", replay: replay, lane: lane,
      requires: requires)
    let optimistic = try operation(send(.submit(spec)))
    let stored = try operation(send(.databaseFinished(optimistic, .done)))
    return send(.databaseFinished(stored, .done))
  }
}
func operation(_ actions: [Action]) throws -> OperationID {
  try #require(actions.compactMap { if case .database(let id, _) = $0 { id } else { nil } }.first)
}
func attempt(_ actions: [Action]) throws -> OperationID {
  try #require(
    actions.compactMap { if case .transmit(let id, _, _) = $0 { id } else { nil } }.first)
}
func transmissions(_ actions: [Action]) -> [Request<String>] {
  actions.compactMap { if case .transmit(_, _, let request) = $0 { request } else { nil } }
}
func dbWork(_ actions: [Action]) -> [DatabaseWork<String>] {
  actions.compactMap { if case .database(_, let work) = $0 { work } else { nil } }
}
func page(_ start: Int64, _ end: Int64) -> Page<String> {
  Page(
    through: end, date: 1, final: false,
    updates: start < end ? ((start + 1)...end).map { Update(sequence: $0, payload: "u\($0)") } : [])
}
func permutations<T>(_ values: [T]) -> [[T]] {
  if values.isEmpty { return [[]] }
  return values.indices.flatMap { i in
    var rest = values
    let first = rest.remove(at: i)
    return permutations(rest).map { [first] + $0 }
  }
}

func credentialOperation(_ actions: [Action]) throws -> OperationID {
  try #require(
    actions.compactMap { if case .credentials(let id, _, _) = $0 { id } else { nil } }.first)
}

func position(_ sequence: Int64, date: Int64? = nil) -> SyncPosition {
  SyncPosition(sequence: sequence, date: date ?? (sequence == 0 ? 0 : 1))
}
enum TestFailure: Error { case unexpectedRepair }
