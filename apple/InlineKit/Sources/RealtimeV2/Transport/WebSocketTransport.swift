import AsyncAlgorithms
import Foundation
import InlineConfig
import InlineProtocol
import Logger

public actor WebSocketTransport: NSObject, Transport, URLSessionWebSocketDelegate {
  private let log = Log.scoped("RealtimeV2.WebSocketTransport", level: .debug)

  private let _eventChannel: AsyncChannel<TransportEvent>
  public nonisolated var events: AsyncChannel<TransportEvent> { _eventChannel }

  // MARK: Internal state -----------------------------------------------------

  private enum ConnectionState { case idle, connecting, connected }
  private var state: ConnectionState = .idle

  private var task: URLSessionWebSocketTask?
  private var receiveLoopTask: Task<Void, Never>?
  private var connectionToken: UInt64 = 0

  private lazy var session: URLSession = { [unowned self] in
    let configuration = URLSessionConfiguration.default
    configuration.shouldUseExtendedBackgroundIdleMode = true
    configuration.timeoutIntervalForResource = 300
    configuration.timeoutIntervalForRequest = 30
    configuration.waitsForConnectivity = false
    configuration.httpMaximumConnectionsPerHost = 1
    configuration.allowsCellularAccess = true
    configuration.isDiscretionary = false
    configuration.networkServiceType = .responsiveData
    configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
    // Use a serial queue to ensure delegate callbacks are serialized and predictable
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.name = "WebSocketTransport.delegate"
    return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
  }()

  private static var defaultURL: URL {
    URL(string: InlineConfig.realtimeServerURL)!
  }

  private let url: URL

  // MARK: Initialization -----------------------------------------------------

  public init(url: URL? = nil) {
    log.trace("initializing")

    _eventChannel = AsyncChannel<TransportEvent>()
    self.url = url ?? Self.defaultURL

    super.init()
  }

  // MARK: Connection helpers -------------------------------------------------

  /// Only called once (ie. on login)
  public func start() async {
    guard state == .idle else {
      log.error("Not starting transport because state is not idle (current: \(state))")
      return
    }
    log.debug("starting transport and opening connection to \(url)")

    await connecting()
    connectionToken = connectionToken &+ 1
    let connectionTokenSnapshot = connectionToken
    await openConnection(expectedToken: connectionTokenSnapshot)
  }

  /// Should be called on logout. Destructive. Do not call for a simple connection restart.
  public func stop() async {
    guard state != .idle else { return }
    log.debug("stopping connection")

    connectionToken = connectionToken &+ 1
    await cleanUpPreviousConnection()
    await idle(errorDescription: "stopped")
  }

  public func send(_ message: InlineProtocol.ClientMessage) async throws {
    guard state == .connected, let task else {
      throw TransportError.notConnected
    }
    log.trace("sending message \(message)")
    let data = try message.serializedData()
    try await task.send(.data(data))
  }

  private func openConnection(expectedToken: UInt64) async {
    guard expectedToken == connectionToken else {
      log.trace("Skipping openConnection for stale token")
      return
    }
    log.trace("Opening connection")
    guard state != .idle else {
      log.debug("Not opening connection because state is idle")
      return
    }

    await cleanUpPreviousConnection()
    await connecting()
    guard expectedToken == connectionToken else {
      log.trace("Skipping openConnection for stale token after connecting")
      return
    }

    let wsTask = session.webSocketTask(with: url)
    task = wsTask

    wsTask.resume()
  }

  private func cleanUpPreviousConnection() async {
    log.trace("cleaning up previous connection task and loop")

    receiveLoopTask?.cancel()
    receiveLoopTask = nil

    if let task {
      task.cancel(with: .goingAway, reason: "cleanup".data(using: .utf8))
    }
    task = nil
  }

  // MARK: Receive loop -------------------------------------------------------

  private func receiveLoop(connectionToken: UInt64, webSocketTask: URLSessionWebSocketTask) {
    receiveLoopTask = Task { [weak self, eventChannel = _eventChannel] in
      guard let self else { return }
      while true {
        do {
          let frame = try await webSocketTask.receive()

          guard await self.isCurrentConnection(token: connectionToken, task: webSocketTask) else { break }

          switch frame {
          case let .data(data):
            if let msg = try? ServerProtocolMessage(serializedBytes: data) {
              await eventChannel.send(.message(msg))
            }
          case .string:
            log.warning("Received string frame, expected binary data. This transport only supports binary protocol buffers.")
            break
          @unknown default:
            break
          }
        } catch {
          guard await self.isCurrentConnection(token: connectionToken, task: webSocketTask) else { break }
          await self.handleDisconnect(error: error)
          break
        }
      }
    }
  }

  private func handleDisconnect(error: Error?) async {
    guard state != .idle else { return }
    await cleanUpPreviousConnection()
    await idle(errorDescription: error.map { String(describing: $0) })
  }

  // MARK: State transitions --------------------------------------------------

  private func connected() async {
    guard state != .connected else { return }
    state = .connected
    log.trace("Transport connected")
    await _eventChannel.send(.connected)
  }

  private func connecting() async {
    guard state != .connecting else { return }
    state = .connecting
    await _eventChannel.send(.connecting)
  }

  private func idle(errorDescription: String?) async {
    state = .idle
    log.trace("Transport disconnected")
    await _eventChannel.send(.disconnected(errorDescription: errorDescription))
  }

  // MARK: - URLSessionWebSocketDelegate ------------------------------------

  public nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    Task { await self.connectionDidOpen(for: webSocketTask) }
  }

  public nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    Task { await self.handleClose(for: webSocketTask, code: closeCode, reason: reason) }
  }

  public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else { return }
    Task { [weak self] in
      guard let self else { return }
      guard let currentTask = await self.task, currentTask === task else { return }
      await self.handleDisconnect(error: error)
    }
  }

  // MARK: Delegate helpers --------------------------------------------------

  private func connectionDidOpen(for task: URLSessionWebSocketTask) async {
    guard self.task === task else {
      log.trace("Ignoring didOpen for stale WebSocket task")
      return
    }

    let token = connectionToken
    receiveLoop(connectionToken: token, webSocketTask: task)

    await connected()
  }

  private func isCurrentConnection(token: UInt64, task: URLSessionWebSocketTask) async -> Bool {
    self.task === task && self.connectionToken == token && self.state != .idle
  }

  private func handleClose(
    for task: URLSessionWebSocketTask,
    code: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) async {
    guard self.task === task else {
      log.trace("Ignoring didClose for stale WebSocket task")
      return
    }

    let errorDescription = "WebSocketClosed:\(code.rawValue)"
    await handleDisconnect(error: NSError(domain: "WebSocketClosed", code: Int(code.rawValue), userInfo: [
      NSLocalizedDescriptionKey: errorDescription
    ]))
  }
}
