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

  private let log = Log.scoped("RealtimeV2.WebSocketTransport")

  nonisolated var events: AsyncStream<TransportEvent> { _eventStream }

  func start() async {
    guard state == .idle else { return }
    log.debug("starting connection to \(url)")
    await openConnection()
  }

  func stop() async {
    guard state == .connected || state == .connecting else { return }
    log.debug("stopping connection")

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

  /// `URLSession` configured with this actor as its delegate so that we can
  /// reliably act on `didOpen`, `didClose` and error callbacks.
  private lazy var session: URLSession = { [unowned self] in
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 300
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()

  // AsyncStream plumbing
  private let _eventStream: AsyncStream<TransportEvent>
  private let continuation: AsyncStream<TransportEvent>.Continuation

  /// Cancels any leftover tasks or sockets from a previous connection attempt.
  /// This prevents multiple receive loops from running in parallel and ensures
  /// that no stale sockets are left dangling when we reconnect.
  private func cleanUpPreviousConnection() {
    // Cancel the detached receive task first so it stops using the socket.
    receiveLoopTask?.cancel()
    receiveLoopTask = nil

    // Cancel the underlying WebSocket task (if any).
    task?.cancel()
    task = nil
  }

  // MARK: Initialisation -----------------------------------------------------

  init(url: URL? = nil) {
    log.trace("initialising")

    // 1. Build the unified AsyncStream first
    var cont: AsyncStream<TransportEvent>.Continuation!
    _eventStream = AsyncStream<TransportEvent> { continuation in
      cont = continuation
    }
    continuation = cont

    // 2. Endpoint (the session is configured lazily)
    self.url = url ?? Self.defaultURL

    super.init()
  }

  private static var defaultURL: URL {
    if ProjectConfig.useProductionApi {
      return URL(string: "wss://api.inline.chat/realtime")!
    }

    #if targetEnvironment(simulator)
    return URL(string: "ws://localhost:8000/realtime")!
    #else
    return URL(string: "wss://api.inline.chat/realtime")!
    #endif
  }

  private let url: URL

  // MARK: Connection helpers -------------------------------------------------

  private func openConnection() async {
    // Ensure we start from a clean slate.
    cleanUpPreviousConnection()

    state = .connecting
    continuation.yield(.connecting)

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
    continuation.finish()
  }

  // MARK: Receive loop -------------------------------------------------------

  private func receiveLoop() {
    guard let task else { return }

    // Keep a reference so we can cancel on reconnect.
    receiveLoopTask = Task.detached { [weak self, webSocketTask = task] in
      guard let self else { return }
      while true {
        do {
          let frame = try await webSocketTask.receive()

          switch frame {
            case let .data(data):
              // TODO: handle failed to decode and log
              if let msg = try? ServerProtocolMessage(serializedBytes: data) {
                continuation.yield(.message(msg))
              }
            case .string:
              // Log warning
              // This transport only supports binary protocol buffers.
              break
            @unknown default:
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
    // Attempt to reconnect transparently: transition back to `.connecting` and
    // try to re-open the socket.  The client will never see a `.disconnected`
    // event; instead it observes `.connecting → .connected` again.

    guard state != .idle else { return }

    // Ensure any artefacts from the previous connection are cleaned up before
    // attempting to reconnect.
    cleanUpPreviousConnection()

    continuation.yield(.connecting)

    // Small delay with jitter to avoid busy-loop in pathological scenarios.
    // TODO: Improve reconnection logic
    let delay = Double.random(in: 0.2 ... 3.0)
    try? await Task.sleep(for: .seconds(delay))

    await openConnection()
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
    Task { await self.handleClose(code: closeCode, reason: reason) }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else { return }
    Task { await self.handleError(error) }
  }

  // MARK: Delegate helpers --------------------------------------------------

  private func connectionDidOpen(for task: URLSessionWebSocketTask) async {
    guard self.task === task else { return }

    state = .connected
    continuation.yield(.connected)

    receiveLoop()
  }

  private func handleClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) async {
    // Treat all closes the same way for now and attempt to reconnect.
    let nsError = NSError(domain: "WebSocketClosed", code: Int(code.rawValue), userInfo: nil)
    await handleError(nsError)
  }
}
