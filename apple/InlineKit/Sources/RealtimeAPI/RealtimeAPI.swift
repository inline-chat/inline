import AsyncAlgorithms
import Auth
import Combine
import Foundation
import InlineProtocol
import Logger

public enum RealtimeAPIState: Sendable {
  case waitingForNetwork
  case connecting
  case updating
  case connected
}

public enum RealtimeAPIEvent: Sendable {
  case stateUpdate(state: RealtimeAPIState)
}

public actor RealtimeAPI: Sendable {
  var transport: WebSocketTransport
  var msgQueue = MsgQueue()
  var log = Log.scoped("Realtime_Core")
  var state: RunState = .paused
  var runTask: Task<Void, Never>?
  var stateChannel = AsyncChannel<Void>()
  var messageChannel = AsyncChannel<Void>()
  var started: Bool = false
  public var updatesEngine: RealtimeUpdatesProtocol

  // publishers
  public let eventsChannel = AsyncChannel<RealtimeAPIEvent>()

  /// Message IDs to continution handlers
  private var rpcCalls: [UInt64: CheckedContinuation<RpcResult.OneOf_Result?, any Error>] = [:]

  public init(updatesEngine: RealtimeUpdatesProtocol) {
    log.debug("initilized realtime core")
    transport = WebSocketTransport()
    self.updatesEngine = updatesEngine
  }

  enum RunState {
    /// while flowing, we send messages one by one, initially flushing queue
    case flowing

    /// while paused, we queue messages
    case paused
  }

  public func start() async throws {
    guard !started else { return }

    log.debug("starting realtime API")

    guard let _ = Auth.shared.getToken() else {
      log.error("No token available")
      throw RealtimeAPIError.notAuthorized
    }

    started = true

    // Start transport
    await setUpTransport()
    await transport.start()

    // Start the run loop
    startRunLoop()
  }

  // MARK: - Runloop

  private func startRunLoop() {
    runTask?.cancel()
    runTask = Task {
      let merged = merge(
        self.stateChannel,
        self.messageChannel
      )

      for await _ in merged {
        guard !Task.isCancelled else { break }

        switch self.state {
          case .flowing:
            await self.processMessages()
          case .paused:
            break // Wait for state change
        }
      }
    }
  }

  private func processMessages() async {
    while state == .flowing, let message = msgQueue.next() {
      do {
        try await transport.send(message)
      } catch {
        handleFailedMessageSend()
        msgQueue.requeue(message)
        break
      }
    }
  }

  private func handleFailedMessageSend() {
    // trigger a reconnect?
    log.debug("failed to send a message")
  }

  private func pauseDelivery() async {
    guard state != .paused else { return }
    state = .paused
    await stateChannel.send(())
    log.debug("paused")
  }

  private func resumeDelivery() async {
    guard state != .flowing else { return }
    state = .flowing
    await stateChannel.send(())
    log.debug("flowing")
  }

  private func authenticate() async {
    log.debug("authenticating")
    // Send connection init
    do {
      let token = Auth.shared.getToken() ?? ""
      let msg = wrapMessage(body: .connectionInit(.with {
        $0.token = token
      }))
      try await transport.send(msg)
    } catch {
      // TODO: Handle
      log.error("Failed to send connection init", error: error)
    }
  }

  // Helpers state
  private var seq: UInt32 = 0
  private let epoch = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00:00 UTC
  private let queue = DispatchQueue(label: "chat.inline.idgenerator")
  private var lastTimestamp: UInt32 = 0
  private var sequence: UInt32 = 0
}

extension RealtimeAPI {
  // MARK: - RPC

  public func invoke(_ method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> RpcResult
    .OneOf_Result?
  {
    let message = wrapMessage(body: .rpcCall(.with {
      $0.method = method
      $0.input = input
    }))

    log.debug("invoking method: \(method)")

    return try await withCheckedThrowingContinuation { continuation in
      msgQueue.push(message: message)
      rpcCalls[message.id] = continuation
      Task {
        await messageChannel.send(())
      }
    }
  }

  private func handleRpcResult(_ result: RpcResult) {
    log
      .debug(
        "received rpc result: \(result.debugDescription)"
      )
    let continuation = rpcCalls.removeValue(forKey: result.reqMsgID)
    continuation?.resume(returning: result.result)
  }

  private func handleRpcError(_ error: RpcError) {
    log
      .debug(
        "received rpc error: \(error.message) code: \(error.errorCode)"
      )
    let continuation = rpcCalls.removeValue(forKey: error.reqMsgID)
    continuation?
      .resume(
        throwing: RealtimeAPIError
          .rpcError(errorCode: error.errorCode, message: error.message)
      )
  }

  // Not used as we want to wait until things get resolved probably.
  private func cancelPendingRpcCalls(reason: RealtimeAPIError) {
    for (_, continuation) in rpcCalls {
      continuation.resume(throwing: reason)
    }
    rpcCalls.removeAll()
  }
}

// MARK: - Transport Integration

extension RealtimeAPI {
  private func setUpTransport() async {
    log.debug("setting up transport")
    await transport.addStateObserver { [weak self] state, networkAvailable in
      Task { [weak self] in
        await self?.transportStateChanged(state: state, networkAvailable: networkAvailable)
      }
    }

    await transport.addMessageHandler { message in
      Task {
        await self.transportMessageReceived(message: message)
      }
    }
  }

  private func transportStateChanged(state: TransportConnectionState, networkAvailable: Bool) async {
    // TODO: make this more accurate by taking authenticating step into account
    let apiState: RealtimeAPIState = switch state {
      case .connected:
        .connected
      case .disconnected, .connecting:
        if networkAvailable { .connecting } else { .waitingForNetwork }
    }
    await eventsChannel.send(.stateUpdate(state: apiState))

    switch state {
      case .connected:
        await authenticate()
      case .disconnected:
        await pauseDelivery()
      default:
        break
    }
  }

  private func transportMessageReceived(message: ServerProtocolMessage) async {
    log.debug("received message")
    switch message.body {
      case .connectionOpen:
        log.info("Connection established")
        await resumeDelivery()

      case let .rpcResult(result):
        handleRpcResult(result)

      case let .rpcError(error):
        handleRpcError(error)

      case let .message(serverMessage):
        switch serverMessage.payload {
          case let .update(update):
            handleUpdate(update)

          default:
            break
        }

      default:
        break
    }
  }

  private func handleUpdate(_ updatesPayload: UpdatesPayload) {
    Task {
      await updatesEngine.applyBatch(updates: updatesPayload.updates)
    }
  }
}

// MARK: - Helpers

extension RealtimeAPI {
  private func wrapMessage(body: ClientMessage.OneOf_Body) -> ClientMessage {
    advanceSeq()
    var clientMsg = ClientMessage()
    clientMsg.body = body
    clientMsg.id = genID()
    clientMsg.seq = seq
    return clientMsg
  }

  private func advanceSeq() {
    seq = seq + 1
  }

  // MARK: - ID

  // Mixes time with sequence number to generate a unique id
  private func genID() -> UInt64 {
    queue.sync {
      let timestamp = currentTimestamp()

      if timestamp == lastTimestamp {
        sequence += 1
      } else {
        sequence = 0
        lastTimestamp = timestamp
      }

      return (UInt64(timestamp) << 32) | UInt64(sequence)
    }
  }

  private func currentTimestamp() -> UInt32 {
    UInt32(Date().timeIntervalSince(epoch))
  }
}
