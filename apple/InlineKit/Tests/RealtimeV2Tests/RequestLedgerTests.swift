import Foundation
import Testing
@testable import RealtimeV2

/// Pure schedules over the direct-RPC ledger. No actors, timers or transports: every
/// interleaving is a list of inputs and the commands they must produce.
@Suite("Request ledger")
struct RequestLedgerTests {
  typealias Ledger = RequestLedger<String, String>
  typealias Command = Ledger.Command

  private func read(_ id: UInt64, _ payload: String = "read") -> Ledger.Request {
    Ledger.Request(id: id, payload: payload, readOnly: true)
  }

  private func write(_ id: UInt64, _ payload: String = "write") -> Ledger.Request {
    Ledger.Request(id: id, payload: payload, readOnly: false)
  }

  /// A ledger that has been told there is no connection.
  private func disconnected() -> Ledger {
    var ledger = Ledger()
    #expect(ledger.handle(.connectionLost) == [])
    return ledger
  }

  /// Submits one request on an open connection and carries it to `.sent`.
  private func sent(_ request: Ledger.Request, connection: UInt64 = 1) -> Ledger {
    var ledger = Ledger()
    _ = ledger.handle(.connectionOpened(connection))
    let prepare = ledger.handle(.submit(request))
    #expect(prepare == [.prepare(request.id, 1, request.payload)])
    #expect(ledger.handle(.prepared(request.id, 1)) == [.transmit(request.id, 1, request.payload)])
    #expect(ledger.handle(.sendSucceeded(request.id, 1)) == [])
    #expect(ledger.phase(of: request.id) == .sent(1))
    return ledger
  }

  // MARK: - Happy path

  @Test("a fresh ledger lets the transport decide, and a refused send proves there is no connection")
  func assumesConnectionUntilRefused() {
    var ledger = Ledger()
    #expect(ledger.isConnected)
    #expect(ledger.handle(.submit(write(1))) == [.prepare(1, 1, "write")])
    #expect(ledger.handle(.prepared(1, 1)) == [.transmit(1, 1, "write")])
    #expect(ledger.handle(.sendFailed(1, 1, .notConnected)) == [])
    #expect(!ledger.isConnected)
    #expect(ledger.phase(of: 1) == .queued)
    // Nothing dispatches, and nothing spins, until an explicit open.
    #expect(ledger.handle(.wake) == [])
    #expect(ledger.handle(.submit(read(2))) == [])
    #expect(ledger.stats.submittedWhileDisconnected == 1)
    #expect(ledger.handle(.connectionOpened(1)) == [.prepare(1, 2, "write"), .prepare(2, 3, "read")])
  }

  @Test("a request submitted while disconnected waits for the first open connection")
  func heldUntilConnectionOpens() {
    var ledger = disconnected()
    #expect(ledger.handle(.submit(read(1))) == [])
    #expect(ledger.pendingCount == 1)
    #expect(ledger.phase(of: 1) == .queued)
    #expect(ledger.stats.submittedWhileDisconnected == 1)

    #expect(ledger.handle(.connectionOpened(7)) == [.prepare(1, 1, "read")])
    #expect(ledger.phase(of: 1) == .preparing(1))
    #expect(ledger.request(1)?.attemptConnection == 7)
  }

  @Test("a request walks prepare, transmit, sent, acknowledged and resolves on its reply")
  func fullLifecycle() {
    var ledger = sent(write(1))
    #expect(ledger.handle(.acknowledged(1, 1)) == [])
    #expect(ledger.phase(of: 1) == .acknowledged(1))
    #expect(ledger.handle(.replied(1, 1, "ok")) == [.resolve(1, .reply("ok"))])
    #expect(ledger.pendingCount == 0)
    #expect(ledger.inFlightCount == 0)
  }

  @Test("dispatch keeps admission order")
  func fifoDispatch() {
    var ledger = disconnected()
    _ = ledger.handle(.submit(read(1, "a")))
    _ = ledger.handle(.submit(write(2, "b")))
    _ = ledger.handle(.submit(read(3, "c")))
    #expect(ledger.handle(.connectionOpened(1)) == [
      .prepare(1, 1, "a"), .prepare(2, 2, "b"), .prepare(3, 3, "c"),
    ])
  }

  @Test("in-flight capacity bounds dispatch and frees a slot per resolution")
  func capacityBound() {
    var ledger = Ledger(configuration: .init(maxInFlight: 2))
    _ = ledger.handle(.connectionOpened(1))
    #expect(ledger.handle(.submit(read(1))) == [.prepare(1, 1, "read")])
    #expect(ledger.handle(.submit(read(2))) == [.prepare(2, 2, "read")])
    #expect(ledger.handle(.submit(read(3))) == [])
    #expect(ledger.phase(of: 3) == .queued)
    _ = ledger.handle(.prepared(1, 1))
    _ = ledger.handle(.sendSucceeded(1, 1))
    #expect(ledger.handle(.replied(1, 1, "ok")) == [.resolve(1, .reply("ok")), .prepare(3, 3, "read")])
  }

  // MARK: - Connection loss

  @Test("a read whose reply was lost with the connection is re-sent on the next one")
  func lostReadIsResent() {
    var ledger = sent(read(1))
    #expect(ledger.handle(.connectionLost) == [])
    #expect(ledger.phase(of: 1) == .queued)
    #expect(ledger.stats.readsResentAfterConnectionLoss == 1)
    #expect(ledger.handle(.connectionOpened(2)) == [.prepare(1, 2, "read")])
    #expect(ledger.request(1)?.attempts == 2)
    #expect(ledger.handle(.prepared(1, 2)) == [.transmit(1, 2, "read")])
    _ = ledger.handle(.sendSucceeded(1, 2))
    #expect(ledger.handle(.replied(1, 2, "late but fine")) == [.resolve(1, .reply("late but fine"))])
  }

  @Test("a write that may have reached the wire is never re-sent after the connection drops")
  func lostWriteIsUncertain() {
    var ledger = sent(write(1))
    #expect(ledger.handle(.connectionLost) == [.resolve(1, .commitOutcomeUnknown)])
    #expect(ledger.stats.writesUncertainAfterConnectionLoss == 1)
    #expect(ledger.handle(.connectionOpened(2)) == [])
  }

  @Test("an acknowledged write is still uncertain once its connection is gone")
  func acknowledgedWriteIsUncertain() {
    var ledger = sent(write(1))
    _ = ledger.handle(.acknowledged(1, 1))
    #expect(ledger.handle(.connectionLost) == [.resolve(1, .commitOutcomeUnknown)])
  }

  @Test("a queued write survives the gap and is sent once on the next connection")
  func queuedWriteSurvives() {
    var ledger = disconnected()
    _ = ledger.handle(.submit(write(1)))
    #expect(ledger.handle(.connectionLost) == [])
    #expect(ledger.handle(.connectionOpened(1)) == [.prepare(1, 1, "write")])
    #expect(ledger.handle(.connectionLost) == [])
    #expect(ledger.request(1)?.connectionLostDuringDispatch == true)
    // Pre-send work finished after the loss: nothing reached the wire, so it waits again.
    #expect(ledger.handle(.prepared(1, 1)) == [])
    #expect(ledger.phase(of: 1) == .queued)
    #expect(ledger.handle(.connectionOpened(2)) == [.prepare(1, 2, "write")])
  }

  @Test("a loss during transmission settles when the adapter reports the write", arguments: [true, false])
  func lossDuringTransmission(readOnly: Bool) {
    var ledger = Ledger()
    _ = ledger.handle(.connectionOpened(1))
    let request = readOnly ? read(1) : write(1)
    _ = ledger.handle(.submit(request))
    _ = ledger.handle(.prepared(1, 1))
    #expect(ledger.phase(of: 1) == .transmitting(1))
    #expect(ledger.handle(.connectionLost) == [])
    if readOnly {
      #expect(ledger.handle(.sendSucceeded(1, 1)) == [])
      #expect(ledger.phase(of: 1) == .queued)
    } else {
      #expect(ledger.handle(.sendSucceeded(1, 1)) == [.resolve(1, .commitOutcomeUnknown)])
    }
  }

  @Test("a transport that refused the bytes proves the write never left, even for mutations")
  func refusedWriteIsRequeued() {
    var ledger = Ledger()
    _ = ledger.handle(.connectionOpened(1))
    _ = ledger.handle(.submit(write(1)))
    _ = ledger.handle(.prepared(1, 1))
    _ = ledger.handle(.connectionLost)
    #expect(ledger.handle(.sendFailed(1, 1, .notConnected)) == [])
    #expect(ledger.phase(of: 1) == .queued)
    #expect(!ledger.isConnected)
    #expect(ledger.handle(.connectionOpened(2)) == [.prepare(1, 2, "write")])
  }

  @Test("a replacement connection without an explicit loss settles the old attempts")
  func replacementConnectionCountsAsLoss() {
    var ledger = Ledger()
    _ = ledger.handle(.connectionOpened(1))
    _ = ledger.handle(.submit(read(1)))
    _ = ledger.handle(.submit(write(2)))
    _ = ledger.handle(.prepared(1, 1))
    _ = ledger.handle(.prepared(2, 2))
    _ = ledger.handle(.sendSucceeded(1, 1))
    _ = ledger.handle(.sendSucceeded(2, 2))
    #expect(ledger.handle(.connectionOpened(2)) == [
      .resolve(2, .commitOutcomeUnknown), .prepare(1, 3, "read"),
    ])
  }

  // MARK: - Send failures and carrier receipts

  @Test("capacity refusal holds dispatch until the wake, then retries")
  func capacityHold() {
    var ledger = Ledger()
    _ = ledger.handle(.connectionOpened(1))
    _ = ledger.handle(.submit(read(1)))
    _ = ledger.handle(.prepared(1, 1))
    #expect(ledger.handle(.sendFailed(1, 1, .capacityExceeded)) == [.wake(after: .milliseconds(250))])
    #expect(ledger.dispatchHeld)
    // A second request during the hold does not dispatch and does not ask for another wake.
    #expect(ledger.handle(.submit(read(2))) == [])
    #expect(ledger.handle(.wake) == [.prepare(1, 2, "read"), .prepare(2, 3, "read")])
    #expect(!ledger.dispatchHeld)
  }

  @Test("an uncertain transport failure re-sends reads and gives up on writes", arguments: [true, false])
  func uncertainSendFailure(readOnly: Bool) {
    var ledger = Ledger()
    _ = ledger.handle(.connectionOpened(1))
    _ = ledger.handle(.submit(readOnly ? read(1) : write(1)))
    _ = ledger.handle(.prepared(1, 1))
    let commands = ledger.handle(.sendFailed(1, 1, .uncertain))
    if readOnly {
      #expect(commands == [.prepare(1, 2, "read")])
    } else {
      #expect(commands == [.resolve(1, .commitOutcomeUnknown)])
    }
  }

  @Test("a pre-execution rejection re-sends after a hold instead of failing the caller")
  func rejectedBeforeExecution() {
    var ledger = sent(write(1))
    #expect(ledger.handle(.rejectedBeforeExecution(1, 1)) == [.wake(after: .milliseconds(500))])
    #expect(ledger.phase(of: 1) == .queued)
    #expect(ledger.stats.rejectedBeforeExecution == 1)
    #expect(ledger.handle(.wake) == [.prepare(1, 2, "write")])
  }

  @Test("a carrier deadline on a read retries it; on a write it is uncertain", arguments: [true, false])
  func carrierOutcomeUnknown(readOnly: Bool) {
    var ledger = sent(readOnly ? read(1) : write(1))
    let commands = ledger.handle(.commitOutcomeUnknown(1, 1))
    if readOnly {
      #expect(commands == [.prepare(1, 2, "read")])
    } else {
      #expect(commands == [.resolve(1, .commitOutcomeUnknown)])
    }
  }

  @Test("a late reply for an attempt the ledger gave up on still resolves the request")
  func lateReplyWins() {
    var ledger = sent(read(1))
    _ = ledger.handle(.connectionLost)
    #expect(ledger.phase(of: 1) == .queued)
    #expect(ledger.handle(.replied(1, 1, "replayed")) == [.resolve(1, .reply("replayed"))])
    #expect(ledger.handle(.connectionOpened(2)) == [])
  }

  // MARK: - Deadlines, cancellation, close

  @Test("a deadline while disconnected is the only source of notConnected")
  func deadlineWhileDisconnected() {
    var ledger = disconnected()
    _ = ledger.handle(.submit(read(1)))
    #expect(ledger.handle(.deadlineReached(1)) == [.resolve(1, .notConnected)])
    #expect(ledger.stats.expiredWhileDisconnected == 1)
  }

  @Test("a deadline on an open connection is a timeout for anything that cannot have executed")
  func deadlineWhileQueuedOnOpenConnection() {
    var ledger = Ledger(configuration: .init(maxInFlight: 1))
    _ = ledger.handle(.connectionOpened(1))
    _ = ledger.handle(.submit(read(1)))
    _ = ledger.handle(.submit(write(2)))
    #expect(ledger.phase(of: 2) == .queued)
    #expect(ledger.handle(.deadlineReached(2)) == [.resolve(2, .timeout)])
    // Pre-send work had not finished either: still known unsent. Attempt numbers are global
    // and request 2 never got one, so request 3 takes attempt 2.
    _ = ledger.handle(.submit(write(3)))
    _ = ledger.handle(.prepared(1, 1))
    _ = ledger.handle(.sendSucceeded(1, 1))
    _ = ledger.handle(.replied(1, 1, "ok"))
    #expect(ledger.phase(of: 3) == .preparing(2))
    #expect(ledger.handle(.deadlineReached(3)) == [.resolve(3, .timeout)])
  }

  @Test("a deadline after the bytes may have left distinguishes reads from writes", arguments: [true, false])
  func deadlineAfterSend(readOnly: Bool) {
    var ledger = sent(readOnly ? read(1) : write(1))
    let expected: Ledger.Outcome = readOnly ? .timeout : .commitOutcomeUnknown
    #expect(ledger.handle(.deadlineReached(1)) == [.resolve(1, expected)])
  }

  @Test("cancellation is honoured unless a write may already have executed")
  func cancellation() {
    var queued = disconnected()
    _ = queued.handle(.submit(write(1)))
    #expect(queued.handle(.cancel(1)) == [.resolve(1, .cancelled)])

    var preparing = Ledger()
    _ = preparing.handle(.connectionOpened(1))
    _ = preparing.handle(.submit(write(1)))
    #expect(preparing.handle(.cancel(1)) == [.resolve(1, .cancelled)])
    // The adapter's pre-send step reports back to a request that no longer exists.
    #expect(preparing.handle(.prepared(1, 1)) == [])

    var sentRead = sent(read(1))
    #expect(sentRead.handle(.cancel(1)) == [.resolve(1, .cancelled)])

    var sentWrite = sent(write(1))
    #expect(sentWrite.handle(.cancel(1)) == [.resolve(1, .commitOutcomeUnknown)])
  }

  @Test("close resolves everything once and later submissions wait for the next connection")
  func close() {
    var ledger = Ledger()
    _ = ledger.handle(.connectionOpened(1))
    _ = ledger.handle(.submit(read(1)))
    _ = ledger.handle(.submit(write(2)))
    _ = ledger.handle(.submit(write(3)))
    _ = ledger.handle(.prepared(1, 1))
    _ = ledger.handle(.prepared(2, 2))
    _ = ledger.handle(.sendSucceeded(1, 1))
    _ = ledger.handle(.sendSucceeded(2, 2))
    #expect(ledger.handle(.close) == [
      .resolve(1, .stopped), .resolve(2, .commitOutcomeUnknown), .resolve(3, .stopped),
    ])
    #expect(ledger.pendingCount == 0)
    #expect(!ledger.isConnected)
    // The same session serves the next login: a later request waits for its connection.
    #expect(ledger.handle(.submit(read(4))) == [])
    #expect(ledger.handle(.connectionOpened(2)) == [.prepare(4, 4, "read")])
  }

  @Test("a locally rejected request resolves without touching the wire")
  func failLocally() {
    var ledger = Ledger()
    _ = ledger.handle(.connectionOpened(1))
    _ = ledger.handle(.submit(write(1)))
    #expect(ledger.handle(.failLocally(1)) == [.resolve(1, .failedLocally)])
    #expect(ledger.handle(.prepared(1, 1)) == [])
  }

  @Test("stale attempt receipts are ignored")
  func staleReceipts() {
    var ledger = sent(read(1))
    #expect(ledger.handle(.sendSucceeded(1, 9)) == [])
    #expect(ledger.handle(.prepared(1, 1)) == [])
    #expect(ledger.handle(.acknowledged(1, 9)) == [])
    #expect(ledger.handle(.commitOutcomeUnknown(1, 9)) == [])
    #expect(ledger.handle(.rejectedBeforeExecution(1, 9)) == [])
    #expect(ledger.handle(.sendFailed(2, 1, .uncertain)) == [])
    #expect(ledger.phase(of: 1) == .sent(1))
  }

  // MARK: - Invariants over generated schedules

  /// Drives the ledger through seeded random schedules and checks the properties the
  /// adapter relies on: every request resolves exactly once by close; a write is never
  /// dispatched again while an earlier attempt may have executed, unless the transport or the
  /// server proved that attempt never did; commands only name live attempts; and in-flight
  /// work never exceeds the configured bound.
  @Test("generated schedules keep the write-safety and single-resolution invariants", arguments: 1 ... 150)
  func generatedSchedules(seed: Int) {
    var rng = SeededGenerator(seed: UInt64(seed))
    var ledger = Ledger(configuration: .init(maxInFlight: Int(rng.next(in: 1 ... 4))))
    var submitted: Set<UInt64> = []
    var resolved: [UInt64: Int] = [:]
    /// Writes whose current attempt may have executed and has not been proven unsent.
    var uncertainWrites: Set<UInt64> = []
    var liveAttempts: [UInt64: UInt64] = [:]
    var readOnly: [UInt64: Bool] = [:]
    var nextID: UInt64 = 0

    func check(_ input: Ledger.Input, _ commands: [Command]) {
      for command in commands {
        switch command {
        case let .prepare(id, attempt, _):
          #expect(submitted.contains(id))
          liveAttempts[id] = attempt
          if readOnly[id] == false {
            #expect(!uncertainWrites.contains(id), "write \(id) re-dispatched after it may have executed (seed \(seed))")
          }
        case let .transmit(id, attempt, _):
          #expect(liveAttempts[id] == attempt)
        case let .resolve(id, _):
          resolved[id, default: 0] += 1
          liveAttempts.removeValue(forKey: id)
          uncertainWrites.remove(id)
        case .wake:
          break
        }
      }
      // Proofs of non-execution: the transport refused the bytes, or the server rejected the
      // attempt before executing it. The ledger must have requeued the request for them to count.
      switch input {
      case let .sendFailed(id, _, .notConnected), let .sendFailed(id, _, .capacityExceeded),
           let .rejectedBeforeExecution(id, _):
        if ledger.phase(of: id) == .queued { uncertainWrites.remove(id) }
      default:
        break
      }
      for (id, request) in ledger.requests where !request.readOnly && request.phase.mayHaveReachedWire {
        uncertainWrites.insert(id)
      }
      #expect(ledger.inFlightCount <= ledger.configuration.maxInFlight)
    }

    func step(_ input: Ledger.Input) {
      check(input, ledger.handle(input))
    }

    for _ in 0 ..< 60 {
      let live = Array(liveAttempts.keys).sorted()
      let pending = Array(ledger.requests.keys).sorted()
      switch rng.next(in: 0 ... 11) {
      case 0, 1:
        nextID += 1
        let isRead = rng.next(in: 0 ... 1) == 0
        readOnly[nextID] = isRead
        submitted.insert(nextID)
        step(.submit(Ledger.Request(id: nextID, payload: "p", readOnly: isRead)))
      case 2:
        step(.connectionOpened(rng.next(in: 1 ... 3)))
      case 3:
        step(.connectionLost)
      case 4:
        if let id = live.randomElement(using: &rng), let attempt = liveAttempts[id] {
          step(.prepared(id, attempt))
        }
      case 5:
        if let id = live.randomElement(using: &rng), let attempt = liveAttempts[id] {
          let failures: [Ledger.SendFailure?] = [nil, nil, .notConnected, .capacityExceeded, .uncertain]
          if let failure = failures.randomElement(using: &rng)! {
            step(.sendFailed(id, attempt, failure))
          } else {
            step(.sendSucceeded(id, attempt))
          }
        }
      case 6:
        if let id = live.randomElement(using: &rng), let attempt = liveAttempts[id] {
          step(.acknowledged(id, attempt))
        }
      case 7:
        if let id = pending.randomElement(using: &rng) {
          step(.replied(id, liveAttempts[id] ?? 0, "ok"))
        }
      case 8:
        if let id = live.randomElement(using: &rng), let attempt = liveAttempts[id] {
          if rng.next(in: 0 ... 1) == 0 {
            step(.commitOutcomeUnknown(id, attempt))
          } else {
            step(.rejectedBeforeExecution(id, attempt))
          }
        }
      case 9:
        if let id = pending.randomElement(using: &rng) {
          step(.deadlineReached(id))
        }
      case 10:
        if let id = pending.randomElement(using: &rng) {
          step(.cancel(id))
        }
      default:
        step(.wake)
      }
    }

    step(.close)
    #expect(ledger.pendingCount == 0)
    for id in submitted {
      #expect(resolved[id] == 1, "request \(id) resolved \(resolved[id] ?? 0) times (seed \(seed))")
    }
  }
}

/// SplitMix64: deterministic across runs and platforms.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func next(in range: ClosedRange<UInt64>) -> UInt64 {
    UInt64.random(in: range, using: &self)
  }
}
