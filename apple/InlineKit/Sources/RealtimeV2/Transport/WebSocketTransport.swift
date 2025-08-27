import AsyncAlgorithms
import Foundation
import InlineConfig
import InlineProtocol
import Logger
import Network

#if canImport(UIKit)
import UIKit
#endif

public actor WebSocketTransport: NSObject, Transport, URLSessionWebSocketDelegate {
  private let log = Log.scoped("RealtimeV2.WebSocketTransport", enableTracing: true)

  private let _eventChannel: AsyncChannel<TransportEvent>
  public nonisolated var events: AsyncChannel<TransportEvent> { _eventChannel }

  // MARK: Internal state -----------------------------------------------------

  private enum ConnectionState { case idle, connecting, connected }
  private var state: ConnectionState = .idle

  private var connectionAttemptNo: UInt64 = 0

  private var task: URLSessionWebSocketTask?
  private var receiveLoopTask: Task<Void, Never>?
  private var reconnectionTask: Task<Void, Never>?
  private var connectionTimeoutTask: Task<Void, Never>?

  private lazy var session: URLSession = { [unowned self] in
    let configuration = URLSessionConfiguration.default
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()

  private static var defaultURL: URL {
    URL(string: InlineConfig.realtimeServerURL)!
  }

  private let url: URL

  private func cleanUpPreviousConnection() {
    log.trace("cleaning up previous connection task and loop")

    // Cancel any active reconnection task to prevent concurrent reconnection attempts
    reconnectionTask?.cancel()
    reconnectionTask = nil

    // Cancel any active connection timeout task
    stopConnectionTimeout()

    // Cancel the detached receive task first so it stops using the socket.
    receiveLoopTask?.cancel()
    receiveLoopTask = nil

    // Cancel the underlying WebSocket task (if any).
    task?.cancel()
    task = nil
  }

  // MARK: Initialization -----------------------------------------------------

  public init(url: URL? = nil) {
    log.trace("initializing")

    _eventChannel = AsyncChannel<TransportEvent>()
    self.url = url ?? Self.defaultURL

    super.init()
  }

  // MARK: Reconnection -------------------------------------------------------

  /// Reconnect after a delay
  private func reconnect(skipDelay: Bool = false) async {
    // Increment connection attempt number. It also invalidates connection timeout task.
    connectionAttemptNo = connectionAttemptNo &+ 1

    reconnectionTask?.cancel()
    reconnectionTask = Task {
      let delay = getReconnectionDelay()

      if !skipDelay {
        // Wait for timeout or a signal to reconnect
        try? await Task.sleep(for: .seconds(delay))
      }

      // Check if we're still trying to reconnect
      guard !Task.isCancelled else { return }
      guard state != .idle, state != .connected else { return }

      // Open a new connection
      log.debug("Reconnection attempt #\(connectionAttemptNo) with \(delay)s delay")
      await openConnection()
    }
  }

  private func getReconnectionDelay() -> TimeInterval {
    let attemptNo = connectionAttemptNo

    if attemptNo >= 8 {
      return 8.0 + Double.random(in: 0.0 ... 5.0)
    }

    // Custom formula: 0.2 + (attempt^1.5 * 0.4)
    // Produces: 0.6, 1.33, 2.28, 3.4, 4.69, 6.12, 7.68s
    return min(8.0, 0.2 + pow(Double(attemptNo), 1.5) * 0.4)
  }

  // MARK: Connection timeout helpers -----------------------------------------

  private func startConnectionTimeout(for wsTask: URLSessionWebSocketTask) {
    let currentAttemptNo = connectionAttemptNo
    connectionTimeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))

      guard let self else { return }

      // Only trigger timeout for the current connection attempt
      guard await connectionAttemptNo == currentAttemptNo else {
        return
      }

      // Only trigger timeout if still connecting (not connected or idle)
      guard await state == .connecting else {
        return
      }

      log.debug("Connection attempt timed out after 10 seconds")

      // Cancel the WebSocket task and trigger error handling
      wsTask.cancel(with: .abnormalClosure, reason: "Connection timeout".data(using: .utf8))

      let timeoutError = NSError(
        domain: "WebSocketConnectionTimeout",
        code: -1_001,
        userInfo: [NSLocalizedDescriptionKey: "Connection attempt timed out after 10 seconds"]
      )
      await handleError(timeoutError)
    }
  }

  private func stopConnectionTimeout() {
    connectionTimeoutTask?.cancel()
    connectionTimeoutTask = nil
  }

  // MARK: Connection helpers -------------------------------------------------

  /// Only called once (ie. on login)
  public func start() async {
    guard state == .idle else {
      log.trace("Not starting transport because state is not idle (current: \(state))")
      return
    }
    log.debug("starting transport and opening connection to \(url)")

    await connecting()
    await openConnection()
  }

  /// Should be called on logout. Destructive. Do not call for a simple connection restart. Use `stopConnection`
  /// instead.
  public func stop() async {
    guard state == .connected || state == .connecting else { return }
    log.debug("stopping connection")

    await idle()
    await stopConnection()
  }

  public func send(_ message: InlineProtocol.ClientMessage) async throws {
    guard state == .connected, let task else {
      throw TransportError.notConnected
    }
    log.trace("sending message \(message)")
    let data = try message.serializedData()
    try await task.send(.data(data))
  }

  public func stopConnection() async {
    log.debug("stopping connection")

    cleanUpPreviousConnection()
  }

  private func openConnection() async {
    // Guard against starting a connection when we shouldn't
    guard state != .idle else {
      log.warning("Not opening connection because state is idle")
      return
    }

    // Ensure we start from a clean slate.
    cleanUpPreviousConnection()

    await connecting()

    let wsTask = session.webSocketTask(with: url)
    task = wsTask

    // Start 10-second connection timeout
    startConnectionTimeout(for: wsTask)

    wsTask.resume()

    // Actual transition to `.connected` happens in the
    // `urlSession(_:webSocketTask:didOpenWithProtocol:)` delegate callback.
  }

  // MARK: Receive loop -------------------------------------------------------

  private func receiveLoop() {
    guard let task else { return }

    // Keep a reference so we can cancel on reconnect.
    receiveLoopTask = Task.detached { [weak self, webSocketTask = task, eventChannel = _eventChannel] in
      guard let self else { return }
      while true {
        do {
          let frame = try await webSocketTask.receive()

          switch frame {
            case let .data(data):
              // TODO: handle failed to decode and log
              if let msg = try? ServerProtocolMessage(serializedBytes: data) {
                await eventChannel.send(.message(msg))
              }
            case .string:
              // Log warning
              log
                .warning(
                  "Received string frame, expected binary data. This transport only supports binary protocol buffers."
                )
              // This transport only supports binary protocol buffers.
              break
            @unknown default:
              // Handle future cases gracefully
              break
          }
        } catch {
          await handleError(error)
          break
        }
      }
    }
  }

  private func handleError(_ error: Error) async {
    log.debug("WebSocket error: \(error)")

    guard state != .idle else {
      log.trace("Ignoring error because state is idle")
      return
    }

    await connecting()
    await reconnect()
  }

  // MARK: State transitions --------------------------------------------------

  private func connected() async {
    guard state != .connected else { return }
    state = .connected
    log.debug("Transport connected")
    Task { await _eventChannel.send(.connected) }
  }

  private func connecting() async {
    guard state != .connecting else { return }
    state = .connecting
    log.debug("Transport connecting (attempt #\(connectionAttemptNo))")
    Task { await _eventChannel.send(.connecting) }
  }

  private func idle() async {
    guard state != .idle else { return }
    state = .idle
    log.debug("Transport stopping")
    Task { await _eventChannel.send(.stopping) }
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
    Task { await self.handleError(error, for: task) }
  }

  // MARK: Delegate helpers --------------------------------------------------

  private func connectionDidOpen(for task: URLSessionWebSocketTask) async {
    guard self.task === task else {
      log.trace("Ignoring didOpen for stale WebSocket task")
      return
    }

    // Reset connection attempt number to 0 since we've successfully connected
    connectionAttemptNo = 0

    // Cancel the connection timeout task since we've successfully connected
    stopConnectionTimeout()

    receiveLoop()

    await connected()
  }

  private func handleClose(
    for task: URLSessionWebSocketTask,
    code: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) async {
    // Only handle close events for the current task to prevent stale callbacks
    guard self.task === task else {
      log.trace("Ignoring didClose for stale WebSocket task")
      return
    }

    // Treat all closes the same way for now and attempt to reconnect.
    let nsError = NSError(domain: "WebSocketClosed", code: Int(code.rawValue), userInfo: nil)
    await handleError(nsError, for: task)
  }

  private func handleError(_ error: Error, for task: URLSessionTask) async {
    // Only handle errors for the current task to prevent stale callbacks
    guard self.task === task else {
      log.trace("Ignoring error for stale task: \(error)")
      return
    }

    await handleError(error)
  }
}
