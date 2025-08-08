import AsyncAlgorithms
import Foundation
import InlineConfig
import InlineProtocol
import Logger
import Network

#if canImport(UIKit)
import UIKit
#endif

// MARK: - WebSocketTransport -------------------------------------------------

/// Lightweight, Swift-Concurrency-first WebSocket implementation that conforms
/// to the new `Transport` protocol.  It purposefully leaves out the advanced
/// ping/reconnect logic of the old `RealtimeAPI.WebSocketTransport` in order to
/// keep the example focused on the *shape* of the API.
actor WebSocketTransport: NSObject, Transport, URLSessionWebSocketDelegate {
  // MARK: Public `Transport` API --------------------------------------------

  private let log = Log.scoped("RealtimeV2.WebSocketTransport", enableTracing: true)

  nonisolated var events: AsyncChannel<TransportEvent> { _eventChannel }

  func start() async {
    guard state == .idle else {
      log.trace("Not starting connection because state is not idle (current: \(state))")
      return
    }
    log.debug("starting connection to \(url)")

    // Transition to connecting state before opening connection
    state = .connecting
    await openConnection()
  }

  func stop() async {
    guard state == .connected || state == .connecting else { return }
    log.debug("stopping connection")

    // Cancel any active reconnection task
    reconnectionTask?.cancel()
    reconnectionTask = nil

    // Cancel the WebSocket task; listeners stay subscribed to the stream.
    task?.cancel(with: .goingAway, reason: nil)

    // Also cancel the detached receive loop so it does not linger.
    receiveLoopTask?.cancel()
    receiveLoopTask = nil

    task = nil

    state = .idle
  }

  func send(_ message: InlineProtocol.ClientMessage) async throws {
    guard state == .connected, let task else {
      throw TransportError.notConnected
    }
    log.trace("sending message \(message)")
    let data = try message.serializedData()
    try await task.send(.data(data))
  }

  // MARK: Internal state -----------------------------------------------------

  private enum ConnectionState { case idle, connecting, connected }
  private var state: ConnectionState = .idle

  private var task: URLSessionWebSocketTask?
  /// Handle to the detached task that continuously receives frames from the
  /// current WebSocket connection.  We keep a reference so it can be cancelled
  /// when tearing down the connection to avoid leaking multiple concurrent
  /// receive loops.
  private var receiveLoopTask: Task<Void, Never>?

  /// Connection attempt ID to ensure delegate callbacks and cleanup operations
  /// only affect the current connection attempt. Prevents stale callbacks from
  /// previous connection attempts from interfering.
  private var connectionAttemptId: UInt64 = 0

  /// Task that handles the current reconnection attempt. Only one reconnection
  /// can be in progress at a time to prevent resource leaks.
  private var reconnectionTask: Task<Void, Never>?

  /// `URLSession` configured with this actor as its delegate so that we can
  /// reliably act on `didOpen`, `didClose` and error callbacks.
  private lazy var session: URLSession = { [unowned self] in
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 300
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()

  // AsyncChannel plumbing
  private let _eventChannel: AsyncChannel<TransportEvent>

  /// Cancels any leftover tasks or sockets from a previous connection attempt.
  /// This prevents multiple receive loops from running in parallel and ensures
  /// that no stale sockets are left dangling when we reconnect.
  private func cleanUpPreviousConnection() {
    log.trace("cleaning up previous connection task and loop")

    // Increment connection attempt ID to invalidate any pending delegate callbacks
    // from the previous connection attempt
    connectionAttemptId = connectionAttemptId &+ 1

    // Cancel any active reconnection task to prevent concurrent reconnection attempts
    reconnectionTask?.cancel()
    reconnectionTask = nil

    // Cancel the detached receive task first so it stops using the socket.
    receiveLoopTask?.cancel()
    receiveLoopTask = nil

    // Cancel the underlying WebSocket task (if any).
    task?.cancel()
    task = nil
  }

  // MARK: Initialization -----------------------------------------------------

  init(url: URL? = nil) {
    log.trace("initializing")

    // 1. Build the unified AsyncChannel first
    _eventChannel = AsyncChannel<TransportEvent>()

    // 2. Endpoint (the session is configured lazily)
    self.url = url ?? Self.defaultURL

    super.init()
  }

  private static var defaultURL: URL {
    URL(string: InlineConfig.realtimeServerURL)!
  }

  private let url: URL

  // MARK: Connection helpers -------------------------------------------------

  private func openConnection() async {
    // Guard against starting a connection when we shouldn't
    guard state != .idle else {
      log.trace("Not opening connection because state is idle")
      return
    }

    // Ensure we start from a clean slate.
    cleanUpPreviousConnection()

    // Double-check state after cleanup - another task might have changed it
    guard state != .idle else {
      log.trace("Not opening connection because state became idle during cleanup")
      return
    }

    if state != .connecting {
      state = .connecting
      log.debug("Transport connecting (attempt #\(connectionAttemptId))")
      Task { await _eventChannel.send(.connecting) }
    }

    let wsTask = session.webSocketTask(with: url)
    task = wsTask
    wsTask.resume()

    // Actual transition to `.connected` happens in the
    // `urlSession(_:webSocketTask:didOpenWithProtocol:)` delegate callback.
  }

  // Note: `stop()` performs lightweight disconnect; we no longer need a
  // separate `closeConnection` that finishes the stream.
  // Keeping this helper in case future enhancements want to finish the stream
  // upon deallocation.
  private func closeAndFinish() {
    task?.cancel()
    task = nil
    _eventChannel.finish()
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

    // Attempt to reconnect transparently: transition back to `.connecting` and
    // try to re-open the socket.  The client will never see a `.disconnected`
    // event; instead it observes `.connecting → .connected` again.

    guard state != .idle else { return }

    // If a reconnection is already in progress, don't start another one
    guard reconnectionTask == nil else {
      log.trace("Reconnection already in progress, ignoring error")
      return
    }

    // Start a reconnection task to handle this error
    reconnectionTask = Task { [weak self] in
      guard let self else { return }

      await connecting()

      // Small delay with jitter to avoid busy-loop in pathological scenarios.
      // TODO: Improve reconnection logic especially timeout amount
      let delay = Double.random(in: 0.5 ... 3.0)
      try? await Task.sleep(for: .seconds(delay))

      // Check if we're still the active reconnection task and haven't been cancelled
      guard !Task.isCancelled else { return }

      await attemptReconnection()
    }
  }

  private func connecting() async {
    guard await state != .connecting else { return }
    state = .connecting
    log.debug("Transport connecting (attempt #\(connectionAttemptId))")
    Task { await _eventChannel.send(.connecting) }
  }

  /// Internal method to handle the actual reconnection logic
  private func attemptReconnection() async {
    await openConnection()

    // Clear the reconnection task since we're done
    reconnectionTask = nil
  }

  // MARK: - URLSessionWebSocketDelegate ------------------------------------

  nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    Task { await self.connectionDidOpen(for: webSocketTask) }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    Task { await self.handleClose(for: webSocketTask, code: closeCode, reason: reason) }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else { return }
    Task { await self.handleError(error, for: task) }
  }

  // MARK: Delegate helpers --------------------------------------------------

  private func connectionDidOpen(for task: URLSessionWebSocketTask) async {
    guard self.task === task else {
      log.trace("Ignoring didOpen for stale WebSocket task")
      return
    }

    state = .connected
    log.debug("Transport connected (attempt #\(connectionAttemptId))")
    await _eventChannel.send(.connected)

    receiveLoop()
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
