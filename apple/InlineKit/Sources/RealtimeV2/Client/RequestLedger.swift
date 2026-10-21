import Foundation

/// Pure ownership of direct RPC requests across transport sessions.
///
/// This is the Sans-I/O core behind `ProtocolSession.callRpc`. The session actor feeds it
/// facts (a caller submitted a request, a connection opened or was lost, a send finished, a
/// reply or acknowledgement arrived, a deadline fired) and executes the commands it returns.
/// The ledger never performs I/O, reads a clock, or spawns a task, so every interleaving can
/// be replayed in tests with plain values.
///
/// The contract callers get (modelled on MtProtoKit's request service):
///
/// - A request outlives the connection it was dispatched on. Read-only requests whose reply
///   was lost with a connection are re-sent on the next open connection. Known-unsent
///   requests (queued, or failed before the transport accepted bytes) are kept for the next
///   connection whatever their kind.
/// - A write whose bytes may have reached the wire is never re-sent blind. It resolves as
///   `commitOutcomeUnknown` and its owner reconciles, exactly as before.
/// - Callers see a reply, a typed server error, an uncertain write, their own cancellation,
///   or their own deadline. Transport teardown is not a caller outcome: `notConnected` is
///   produced only when the deadline passes while no connection is open, and `stopped` only
///   when the owner closes the ledger for good.
struct RequestLedger<Payload: Sendable, Reply: Sendable>: Sendable {
  typealias RequestID = UInt64
  typealias Attempt = UInt64
  typealias ConnectionID = UInt64

  enum Phase: Equatable, Sendable {
    /// Waiting for an open connection, a free dispatch slot, or the end of a dispatch hold.
    case queued
    /// The adapter is running pre-send work for `attempt`; nothing has reached the wire.
    case preparing(Attempt)
    /// The adapter handed `attempt` to the transport; bytes may or may not have been accepted.
    case transmitting(Attempt)
    /// The transport accepted the bytes; no acknowledgement or reply yet.
    case sent(Attempt)
    /// The server acknowledged receipt of `attempt`; the reply is pending.
    case acknowledged(Attempt)

    var attempt: Attempt? {
      switch self {
      case .queued: nil
      case let .preparing(attempt), let .transmitting(attempt), let .sent(attempt),
           let .acknowledged(attempt):
        attempt
      }
    }

    /// Whether this attempt may have executed on the server.
    var mayHaveReachedWire: Bool {
      switch self {
      case .queued, .preparing: false
      case .transmitting, .sent, .acknowledged: true
      }
    }
  }

  struct Request: Sendable {
    let id: RequestID
    let payload: Payload
    /// Read-only requests are safe to re-send; their effects are idempotent by definition.
    let readOnly: Bool
    fileprivate(set) var phase: Phase = .queued
    /// Number of send attempts issued so far, including the current one.
    fileprivate(set) var attempts: Int = 0
    /// Connection the current attempt was dispatched on.
    fileprivate(set) var attemptConnection: ConnectionID?
    /// The connection was lost while an attempt was being prepared or transmitted.
    fileprivate(set) var connectionLostDuringDispatch = false

    init(id: RequestID, payload: Payload, readOnly: Bool) {
      self.id = id
      self.payload = payload
      self.readOnly = readOnly
    }
  }

  enum Outcome: Sendable {
    case reply(Reply)
    /// The deadline passed while no connection was open.
    case notConnected
    /// The deadline passed on an open connection (queued behind capacity, or awaiting a reply).
    case timeout
    /// A write may have executed; the owner must reconcile instead of re-sending.
    case commitOutcomeUnknown
    /// The caller cancelled before any attempt could have reached the wire.
    case cancelled
    /// The owner ended the account generation before the request resolved.
    case stopped
    /// The adapter's pre-send work rejected the request; the adapter holds the error.
    case failedLocally
  }

  enum SendFailure: Equatable, Sendable {
    /// The transport rejected the message before accepting any bytes.
    case notConnected
    /// The transport rejected admission before accepting any bytes.
    case capacityExceeded
    /// The transport failed after possibly accepting bytes.
    case uncertain
  }

  enum Input: Sendable {
    case submit(Request)
    case connectionOpened(ConnectionID)
    case connectionLost
    /// Pre-send work finished; the ledger decides whether this attempt still transmits.
    case prepared(RequestID, Attempt)
    case sendSucceeded(RequestID, Attempt)
    case sendFailed(RequestID, Attempt, SendFailure)
    case acknowledged(RequestID, Attempt)
    case replied(RequestID, Attempt, Reply)
    /// The carrier gave up on this attempt without knowing whether it executed.
    case commitOutcomeUnknown(RequestID, Attempt)
    /// The server proved this attempt never entered execution.
    case rejectedBeforeExecution(RequestID, Attempt)
    case deadlineReached(RequestID)
    case cancel(RequestID)
    case failLocally(RequestID)
    /// A previously requested `.wake` fired.
    case wake
    case close
  }

  enum Command: Sendable {
    /// Run pre-send work for this attempt, then report `.prepared`.
    case prepare(RequestID, Attempt, Payload)
    /// Hand this attempt to the transport, then report `.sendSucceeded` or `.sendFailed`.
    case transmit(RequestID, Attempt, Payload)
    case resolve(RequestID, Outcome)
    /// Call `.wake` after this delay. The adapter coalesces overlapping requests.
    case wake(after: Duration)
  }

  /// Bounded, payload-free counters for diagnostics.
  struct Stats: Equatable, Sendable {
    var submittedWhileDisconnected = 0
    var readsResentAfterConnectionLoss = 0
    var writesUncertainAfterConnectionLoss = 0
    var expiredWhileDisconnected = 0
    var rejectedBeforeExecution = 0
  }

  struct Configuration: Sendable {
    /// Requests in `preparing`, `transmitting`, `sent` or `acknowledged` on one connection.
    var maxInFlight: Int
    /// Hold before retrying dispatch after the transport refused admission.
    var capacityRetryDelay: Duration
    /// Hold before retrying dispatch after the server rejected an attempt pre-execution.
    var rejectionRetryDelay: Duration

    init(
      maxInFlight: Int = 64,
      capacityRetryDelay: Duration = .milliseconds(250),
      rejectionRetryDelay: Duration = .milliseconds(500)
    ) {
      self.maxInFlight = max(1, maxInFlight)
      self.capacityRetryDelay = capacityRetryDelay
      self.rejectionRetryDelay = rejectionRetryDelay
    }
  }

  let configuration: Configuration
  private(set) var connection: ConnectionID?
  /// Until the first explicit open or loss, the ledger lets the transport decide: a send is
  /// attempted at once and a refused send proves there is no connection. This keeps the
  /// pre-ledger behaviour for owners that never report session edges.
  private(set) var assumesConnection = true
  private(set) var requests: [RequestID: Request] = [:]
  /// FIFO admission order; dispatch and resolution preserve it.
  private var order: [RequestID] = []
  private var nextAttempt: Attempt = 0
  /// Dispatch is paused until the next `.wake` or `.connectionOpened`.
  private(set) var dispatchHeld = false
  private(set) var stats = Stats()

  init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  var pendingCount: Int { requests.count }
  /// Whether dispatch may proceed: a known open connection, or one not yet disproven.
  var isConnected: Bool { connection != nil || assumesConnection }

  var inFlightCount: Int {
    requests.values.reduce(into: 0) { count, request in
      if request.phase != .queued { count += 1 }
    }
  }

  func request(_ id: RequestID) -> Request? { requests[id] }

  func phase(of id: RequestID) -> Phase? { requests[id]?.phase }

  // MARK: - Transitions

  mutating func handle(_ input: Input) -> [Command] {
    var output: [Command] = []
    switch input {
    case let .submit(request):
      guard requests[request.id] == nil else { return output }
      requests[request.id] = request
      order.append(request.id)
      if !isConnected { stats.submittedWhileDisconnected += 1 }
      pump(into: &output)

    case let .connectionOpened(id):
      if connection != nil, connection != id {
        // A replacement arrived without an explicit loss; everything dispatched on the old
        // connection is as lost as if the loss had been reported.
        loseConnection(into: &output)
      }
      assumesConnection = false
      connection = id
      dispatchHeld = false
      pump(into: &output)

    case .connectionLost:
      loseConnection(into: &output)

    case let .prepared(id, attempt):
      guard var request = requests[id], request.phase == .preparing(attempt) else { return output }
      if request.connectionLostDuringDispatch || !isConnected
        || request.attemptConnection != connection
      {
        // Nothing reached the wire. Keep the request for the next connection.
        request.phase = .queued
        request.attemptConnection = nil
        request.connectionLostDuringDispatch = false
        requests[id] = request
        pump(into: &output)
        return output
      }
      request.phase = .transmitting(attempt)
      requests[id] = request
      output.append(.transmit(id, attempt, request.payload))

    case let .sendSucceeded(id, attempt):
      guard var request = requests[id], request.phase == .transmitting(attempt) else { return output }
      if request.connectionLostDuringDispatch {
        // The connection died while the write was in progress. Reads are safe to re-send;
        // writes may have executed.
        settleLostAttempt(&request, into: &output)
        return output
      }
      request.phase = .sent(attempt)
      requests[id] = request

    case let .sendFailed(id, attempt, failure):
      guard var request = requests[id], request.phase == .transmitting(attempt) else { return output }
      switch failure {
      case .notConnected:
        // The transport proved there is no connection, whatever the ledger assumed or the
        // owner has reported so far. Nothing dispatches until the next explicit open.
        requeue(&request)
        assumesConnection = false
        connection = nil
      case .capacityExceeded:
        requeue(&request)
        hold(for: configuration.capacityRetryDelay, into: &output)
      case .uncertain:
        if request.readOnly {
          requeue(&request)
          pump(into: &output)
        } else {
          resolve(id, .commitOutcomeUnknown, into: &output)
        }
      }

    case let .acknowledged(id, attempt):
      guard var request = requests[id], request.phase == .sent(attempt) else { return output }
      request.phase = .acknowledged(attempt)
      requests[id] = request

    case let .replied(id, _, reply):
      // A reply is authoritative whichever attempt produced it, including a late reply for an
      // attempt the ledger already gave up on and requeued.
      guard requests[id] != nil else { return output }
      resolve(id, .reply(reply), into: &output)
      pump(into: &output)

    case let .commitOutcomeUnknown(id, attempt):
      guard var request = requests[id], request.phase.attempt == attempt,
            request.phase.mayHaveReachedWire else { return output }
      if request.readOnly {
        // The carrier gave up on a read; retrying it is harmless.
        requeue(&request)
        pump(into: &output)
      } else {
        resolve(id, .commitOutcomeUnknown, into: &output)
        pump(into: &output)
      }

    case let .rejectedBeforeExecution(id, attempt):
      guard var request = requests[id], request.phase.attempt == attempt,
            request.phase != .queued else { return output }
      stats.rejectedBeforeExecution += 1
      requeue(&request)
      // The server is shedding load; a short hold keeps this from becoming a retry burst.
      hold(for: configuration.rejectionRetryDelay, into: &output)

    case let .deadlineReached(id):
      guard let request = requests[id] else { return output }
      switch request.phase {
      case .queued, .preparing:
        if isConnected {
          resolve(id, .timeout, into: &output)
        } else {
          stats.expiredWhileDisconnected += 1
          resolve(id, .notConnected, into: &output)
        }
      case .transmitting, .sent, .acknowledged:
        resolve(id, request.readOnly ? .timeout : .commitOutcomeUnknown, into: &output)
      }
      pump(into: &output)

    case let .cancel(id):
      guard let request = requests[id] else { return output }
      if request.phase.mayHaveReachedWire, !request.readOnly {
        resolve(id, .commitOutcomeUnknown, into: &output)
      } else {
        resolve(id, .cancelled, into: &output)
      }
      pump(into: &output)

    case let .failLocally(id):
      guard requests[id] != nil else { return output }
      resolve(id, .failedLocally, into: &output)
      pump(into: &output)

    case .wake:
      dispatchHeld = false
      pump(into: &output)

    case .close:
      // The owner ended this account generation. Everything pending resolves now; the ledger
      // itself stays usable, because the same session serves the next login.
      connection = nil
      assumesConnection = false
      dispatchHeld = false
      for id in order {
        guard let request = requests[id] else { continue }
        if request.phase.mayHaveReachedWire, !request.readOnly {
          resolve(id, .commitOutcomeUnknown, into: &output)
        } else {
          resolve(id, .stopped, into: &output)
        }
      }
    }
    return output
  }

  // MARK: - Helpers

  private var canDispatch: Bool {
    isConnected && !dispatchHeld && inFlightCount < configuration.maxInFlight
  }

  private mutating func pump(into output: inout [Command]) {
    guard canDispatch else { return }
    var inFlight = inFlightCount
    for id in order {
      guard inFlight < configuration.maxInFlight else { return }
      guard var request = requests[id], request.phase == .queued else { continue }
      nextAttempt &+= 1
      request.attempts += 1
      request.phase = .preparing(nextAttempt)
      request.attemptConnection = connection
      request.connectionLostDuringDispatch = false
      requests[id] = request
      inFlight += 1
      output.append(.prepare(id, nextAttempt, request.payload))
    }
  }

  private mutating func loseConnection(into output: inout [Command]) {
    connection = nil
    assumesConnection = false
    dispatchHeld = false
    for id in order {
      guard var request = requests[id] else { continue }
      switch request.phase {
      case .queued:
        continue
      case .preparing, .transmitting:
        // The adapter still owns this attempt; settle when it reports back.
        request.connectionLostDuringDispatch = true
        requests[id] = request
      case .sent, .acknowledged:
        settleLostAttempt(&request, into: &output)
      }
    }
  }

  /// The connection that carried `request`'s attempt is gone and its reply will never arrive.
  private mutating func settleLostAttempt(_ request: inout Request, into output: inout [Command]) {
    if request.readOnly {
      stats.readsResentAfterConnectionLoss += 1
      requeue(&request)
      pump(into: &output)
    } else {
      stats.writesUncertainAfterConnectionLoss += 1
      resolve(request.id, .commitOutcomeUnknown, into: &output)
    }
  }

  private mutating func requeue(_ request: inout Request) {
    request.phase = .queued
    request.attemptConnection = nil
    request.connectionLostDuringDispatch = false
    requests[request.id] = request
  }

  private mutating func hold(for delay: Duration, into output: inout [Command]) {
    guard !dispatchHeld else { return }
    dispatchHeld = true
    output.append(.wake(after: delay))
  }

  private mutating func resolve(_ id: RequestID, _ outcome: Outcome, into output: inout [Command]) {
    guard requests.removeValue(forKey: id) != nil else { return }
    order.removeAll { $0 == id }
    output.append(.resolve(id, outcome))
  }
}

extension RequestLedger.Command: Equatable where Payload: Equatable, Reply: Equatable {}
extension RequestLedger.Outcome: Equatable where Reply: Equatable {}
