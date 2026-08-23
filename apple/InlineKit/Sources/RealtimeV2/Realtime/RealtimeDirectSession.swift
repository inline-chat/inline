import Auth
import Foundation
import InlineProtocol

/// A single short-lived realtime connection for auxiliary processes that only issue direct RPCs.
///
/// Unlike `RealtimeV2`, this owner deliberately has no sync engine, durable transaction queue,
/// database projection, or application lifecycle observers. Unsolicited durable updates release
/// their in-process receive receipt without being applied; the account owner's ordinary bucket
/// catch-up remains responsible for them. `finish()` is terminal; create a new instance for a new
/// extension request.
public final actor RealtimeDirectSession {
  private let auth: AuthHandle
  private let session: ProtocolSession
  private let connectionManager: ConnectionManager
  private let connectionAdmissionTimeout: Duration

  private var eventDrainTask: Task<Void, Never>?
  private var started = false
  private var finished = false

  public init(
    transport: any Transport,
    auth: AuthHandle,
    connectionAdmissionTimeout: Duration = .seconds(10)
  ) {
    self.auth = auth
    self.connectionAdmissionTimeout = connectionAdmissionTimeout
    let session = ProtocolSession(transport: transport, auth: auth)
    self.session = session
    connectionManager = ConnectionManager(
      session: session,
      constraints: ConnectionConstraints(
        authAvailable: auth.isLoggedIn(),
        networkAvailable: true,
        appActive: true,
        userWantsConnection: true
      )
    )
  }

  /// Starts or nudges this request's connection. Idempotent until `finish()`.
  public func connectIfNeeded() async {
    guard !finished, auth.isLoggedIn() else { return }
    await startIfNeeded()
    await connectionManager.setAuthAvailable(true)
    await connectionManager.connectNow()
  }

  public func callRpcDirect(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration? = .seconds(15)
  ) async throws -> RpcResult.OneOf_Result? {
    guard !finished else { throw RealtimeDirectRpcError.notConnected }
    guard auth.isLoggedIn() else { throw RealtimeDirectRpcError.notAuthorized }

    await connectIfNeeded()
    // Admission is bounded before execution. Once admitted, the RPC's own timeout owns
    // its complete execution window; this is not a whole-operation or upload deadline.
    guard await waitUntilOpen(timeout: connectionAdmissionTimeout) else {
      try Task.checkCancellation()
      throw RealtimeDirectRpcError.notConnected
    }

    do {
      return try await session.callRpc(method: method, input: input, timeout: timeout)
    } catch let error as ProtocolSessionError {
      switch error {
        case .notAuthorized:
          throw RealtimeDirectRpcError.notAuthorized
        case .notConnected, .stopped:
          throw RealtimeDirectRpcError.notConnected
        case .timeout:
          throw RealtimeDirectRpcError.timeout
        case .commitOutcomeUnknown:
          throw RealtimeDirectRpcError.commitOutcomeUnknown
        case .capacityExceeded:
          throw RealtimeDirectRpcError.capacityExceeded
        case let .rpcError(errorCode, message, code):
          throw RealtimeDirectRpcError.rpcError(errorCode: errorCode, message: message, code: code)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw RealtimeDirectRpcError.unknown(error)
    }
  }

  /// Final teardown for this request-scoped owner. A retry must create a fresh instance.
  public func finish() async {
    guard !finished else { return }
    finished = true
    await connectionManager.stop()
    await connectionManager.finishSessionEventForwarding()
    let task = eventDrainTask
    eventDrainTask = nil
    task?.cancel()
    await task?.value
  }

  private func startIfNeeded() async {
    guard !started, !finished else { return }
    started = true

    let manager = connectionManager
    eventDrainTask = Task {
      for await envelope in await manager.sessionEvents() {
        guard !Task.isCancelled else {
          await envelope.markProcessed()
          return
        }
        // Direct requests own no application projection. Releasing the receipt keeps the
        // protocol receive loop moving without claiming that an unsolicited update was applied.
        await envelope.markProcessed()
      }
    }

    await session.start()
    await connectionManager.start()
  }

  private func waitUntilOpen(timeout: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while !finished, !Task.isCancelled {
      if await connectionManager.currentSnapshot().state == .open {
        return true
      }
      guard clock.now < deadline else { return false }
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return false
      }
    }
    return false
  }
}
