/// Named workflow entry points for callers. `handle` exposes the same transitions
/// as values for recording/replaying a scenario; there is no second implementation.
extension RealtimeCore {
  public mutating func start(generation: UInt64, at time: Tick) -> [Output<Payload>] {
    handle(.start(generation: generation), at: time)
  }
  public mutating func bootstrap(user: BucketID, at time: Tick) -> [Output<Payload>] {
    handle(.bootstrap(user: user), at: time)
  }
  public mutating func restore(generation: UInt64, at time: Tick) -> [Output<Payload>] {
    handle(.start(generation: generation, transactions: .restore), at: time)
  }
  public mutating func submit(_ transaction: Transaction<Payload>, at time: Tick) -> [Output<
    Payload
  >] {
    handle(.submit(transaction), at: time)
  }
  public mutating func request(_ call: Call<Payload>, at time: Tick) -> [Output<Payload>] {
    handle(.request(call), at: time)
  }
  public mutating func cancel(_ call: CallID, at time: Tick) -> [Output<Payload>] {
    handle(.cancelCall(call), at: time)
  }
  public mutating func call(_ payload: Payload, at time: Tick) -> [Output<Payload>] {
    handle(.call(payload), at: time)
  }
  public mutating func catchUp(_ bucket: BucketID, through target: Int64?, at time: Tick)
    -> [Output<Payload>]
  {
    handle(.catchUp(bucket, through: target), at: time)
  }
  public mutating func connectionOpened(_ connection: OperationID, at time: Tick) -> [Output<
    Payload
  >] {
    handle(.connected(connection), at: time)
  }
  public mutating func credentialsFinished(
    _ operation: OperationID, result: CredentialResult, at time: Tick
  ) -> [Output<Payload>] {
    handle(.credentialsFinished(operation, result), at: time)
  }
  public mutating func connectionClosed(_ connection: OperationID, at time: Tick) -> [Output<
    Payload
  >] {
    handle(.disconnected(connection), at: time)
  }
  public mutating func receive(
    _ response: Response<Payload>, for attempt: OperationID, at time: Tick
  ) -> [Output<Payload>] {
    handle(.response(attempt, response), at: time)
  }
  public mutating func receive(
    _ update: Update<Payload>, in bucket: BucketID, generation: UInt64, at time: Tick
  )
    -> [Output<Payload>]
  {
    handle(.live(bucket, update, generation: generation), at: time)
  }
  public mutating func databaseFinished(
    _ operation: OperationID, result: DatabaseResult<Payload>, at time: Tick
  ) -> [Output<Payload>] {
    handle(.databaseFinished(operation, result), at: time)
  }
  public mutating func sendFinished(_ attempt: OperationID, at time: Tick) -> [Output<Payload>] {
    handle(.sendFinished(attempt), at: time)
  }
  public mutating func timeout(at time: Tick) -> [Output<Payload>] { handle(.timeout, at: time) }
  public mutating func stop(at time: Tick) -> [Output<Payload>] { handle(.stop, at: time) }
}
