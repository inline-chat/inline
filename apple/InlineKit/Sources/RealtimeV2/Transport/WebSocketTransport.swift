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
  private let log = Log.scoped("RealtimeV2.WebSocketTransport", level: .debug)

  private let _eventChannel: AsyncChannel<TransportEvent>
  public nonisolated var events: AsyncChannel<TransportEvent> { _eventChannel }

  // MARK: Internal state -----------------------------------------------------

  private enum ConnectionState { case idle, connecting, connected }
  private var state: ConnectionState = .idle

  private var connectionAttemptNo: UInt64 = 0
  private var connectingStartTime: Date?

  private var task: URLSessionWebSocketTask?
  private var receiveLoopTask: Task<Void, Never>?
  private var reconnectionTask: Task<Void, Never>?
  private var connectionTimeoutTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var pathMonitor: NWPathMonitor?
  private var networkAvailable = true
  private var reconnectionInProgress = false
  private var reconnectionToken: UInt64 = 0
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
    if let task {
      task.cancel(with: .goingAway, reason: "cleanup".data(using: .utf8))
    }
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
  public func reconnect(skipDelay: Bool = false) async {
    await scheduleReconnect(skipDelay: skipDelay, reason: .manual)
  }

  public func handleForegroundTransition() async {
    // Reset backoff and immediately attempt to reconnect.
    connectionAttemptNo = 0
    await scheduleReconnect(skipDelay: true, reason: .foreground)
  }

  private enum ReconnectReason: String {
    case manual
    case foreground
    case networkAvailable
    case error
  }

  private func scheduleReconnect(skipDelay: Bool, reason: ReconnectReason) async {
    guard state != .idle else {
      log.debug("Skipping reconnect because state is idle reason=\(reason.rawValue)")
      return
    }

    if reconnectionInProgress {
      log.trace("Coalescing reconnect request skipDelay=\(skipDelay ? 1 : 0) reason=\(reason.rawValue)")
    }

    reconnectionToken = reconnectionToken &+ 1
    let token = reconnectionToken
    connectionToken = connectionToken &+ 1
    let connectionTokenSnapshot = connectionToken
    reconnectionInProgress = true

    reconnectionTask?.cancel()

    await connecting()
    await stopConnection()

    // Increment connection attempt number. It also invalidates connection timeout task.
    connectionAttemptNo = connectionAttemptNo &+ 1

    let delay = getReconnectionDelay()
    log.trace("Reconnection attempt #\(connectionAttemptNo) delay=\(delay)s skipDelay=\(skipDelay ? 1 : 0) reason=\(reason.rawValue)")

    reconnectionTask = Task { [weak self] in
      guard let self else { return }
      defer { Task { await self.finishReconnect(token: token) } }

      if !skipDelay {
        // Wait for timeout or a signal to reconnect
        try? await Task.sleep(for: .seconds(delay))
      }

      // Check if we're still trying to reconnect
      guard !Task.isCancelled else { return }
      guard await self.state != .idle else {
        self.log.debug("Not reconnecting because state is idle reason=\(reason.rawValue)")
        return
      }

      // Open a new connection
      await self.openConnection(expectedToken: connectionTokenSnapshot)
    }
  }

  private func finishReconnect(token: UInt64) async {
    guard token == reconnectionToken else { return }
    reconnectionInProgress = false
    reconnectionTask = nil
  }

  private func getReconnectionDelay() -> TimeInterval {
    let attemptNo = connectionAttemptNo

    if attemptNo >= 8 {
      return 7.0 + Double.random(in: 0.0 ... 4.0)
    }

    // Custom formula: 0.2 + (attempt^1.5 * 0.4)
    // Produces: 0.6, 1.33, 2.28, 3.4, 4.69, 6.12, 7.68s
    return min(8.0, 0.2 + pow(Double(attemptNo), 1.5) * 0.4)
  }

  // MARK: Watchdog helpers ---------------------------------------------------

  private func startWatchdog() {
    stopWatchdog()
    watchdogTask = Task.detached { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))

        guard let self else { return }
        guard !Task.isCancelled else { return }

        if await isStuckConnecting() {
          log.debug("Watchdog: detected stuck connection, triggering recovery")
          await handleStuckConnection()
        }
      }
    }
  }

  private func stopWatchdog() {
    watchdogTask?.cancel()
    watchdogTask = nil
  }

  private func isStuckConnecting() async -> Bool {
    guard state == .connecting else { return false }

    // Check if we have no active recovery tasks (indicating truly stuck state)
    let hasNoActiveTasks = reconnectionTask == nil && connectionTimeoutTask == nil

    // Check if we've been connecting for too long (covers client-layer issues too)
    let connectingSeconds = max(0, connectingStartTime.map { Date().timeIntervalSince($0) } ?? 0)
    let hasBeenConnectingTooLong = connectingSeconds > 60

    // Consider stuck if either condition is true:
    // 1. No active tasks (immediate stuck detection)
    // 2. Been connecting for over 60 seconds (covers auth/protocol issues)
    let isStuck = hasNoActiveTasks || hasBeenConnectingTooLong
    if isStuck {
      log.warning(
        "Watchdog: stuck connecting detected noRecoveryTasks=\(hasNoActiveTasks ? 1 : 0) connectingSeconds=\(Int(connectingSeconds)) attempt=\(connectionAttemptNo)"
      )
    }
    return isStuck
  }

  private func handleStuckConnection() async {
    log.warning("Watchdog: handling stuck connection")
    // Use the same logic as error handling to trigger reconnection
    await handleError(NSError(
      domain: "WatchdogRecovery",
      code: -2_001,
      userInfo: [NSLocalizedDescriptionKey: "Watchdog detected stuck connection"]
    ))
  }

  // MARK: Network monitoring -------------------------------------------------

  private func startNetworkMonitoring() {
    guard pathMonitor == nil else { return }
    log.trace("Setting up network monitoring")
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      Task { await self?.handlePathUpdate(path) }
    }
    monitor.start(queue: DispatchQueue(label: "RealtimeV2.WebSocketTransport.path"))
    pathMonitor = monitor
  }

  private func stopNetworkMonitoring() {
    pathMonitor?.cancel()
    pathMonitor = nil
  }

  private func handlePathUpdate(_ path: NWPath) async {
    let isSatisfied = path.status == .satisfied
    guard networkAvailable != isSatisfied else { return }
    networkAvailable = isSatisfied

    guard state != .idle else { return }

    if isSatisfied {
      log.debug("Network became available; reconnecting")
      connectionAttemptNo = 0
      await scheduleReconnect(skipDelay: true, reason: .networkAvailable)
    } else {
      log.debug("Network became unavailable; stopping connection")
      connectionToken = connectionToken &+ 1
      await connecting()
      await stopConnection()
      stopWatchdog()
    }
  }

  // MARK: Connection timeout helpers -----------------------------------------

  private func startConnectionTimeout(for wsTask: URLSessionWebSocketTask) {
    let currentAttemptNo = connectionAttemptNo
    connectionTimeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))

      guard let self else { return }
      guard !Task.isCancelled else { return }

      // Only trigger timeout for the current connection attempt
      guard await connectionAttemptNo == currentAttemptNo else {
        return
      }

      // Only trigger timeout if still connecting (not connected or idle)
      guard await state == .connecting else {
        return
      }

      // Final check: ensure this is still the active task before cancelling
      guard await task === wsTask else {
        return
      }

      log.warning("Connection attempt timed out after 10 seconds")

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
      log.error("Not starting transport because state is not idle (current: \(state))")
      return
    }
    log.debug("starting transport and opening connection to \(url)")

    await connecting()
    startNetworkMonitoring()
    startWatchdog()
    connectionToken = connectionToken &+ 1
    let connectionTokenSnapshot = connectionToken
    await openConnection(expectedToken: connectionTokenSnapshot)
  }

  /// Should be called on logout. Destructive. Do not call for a simple connection restart. Use `stopConnection`
  /// instead.
  public func stop() async {
    guard state == .connected || state == .connecting else { return }
    log.debug("stopping connection")

    stopWatchdog()
    stopNetworkMonitoring()
    reconnectionTask?.cancel()
    reconnectionTask = nil
    reconnectionInProgress = false
    connectionToken = connectionToken &+ 1
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
    log.trace("stopping connection")

    cleanUpPreviousConnection()
  }

  private func openConnection(expectedToken: UInt64) async {
    guard expectedToken == connectionToken else {
      log.trace("Skipping openConnection for stale token")
      return
    }
    log.trace("Opening connection")
    // Guard against starting a connection when we shouldn't
    guard state != .idle else {
      log.debug("Not opening connection because state is idle")
      return
    }

    // Ensure we start from a clean slate.
    cleanUpPreviousConnection()

    await connecting()
    guard expectedToken == connectionToken else {
      log.trace("Skipping openConnection for stale token after connecting")
      return
    }

    let wsTask = session.webSocketTask(with: url)
    task = wsTask

    // Start 10-second connection timeout
    startConnectionTimeout(for: wsTask)

    wsTask.resume()

    // Actual transition to `.connected` happens in the
    // `urlSession(_:webSocketTask:didOpenWithProtocol:)` delegate callback.
  }

  // MARK: Receive loop -------------------------------------------------------

  private func receiveLoop(connectionToken: UInt64, webSocketTask: URLSessionWebSocketTask) {
    // Keep a reference so we can cancel on reconnect.
    receiveLoopTask = Task.detached { [weak self, eventChannel = _eventChannel] in
      guard let self else { return }
      while true {
        do {
          let frame = try await webSocketTask.receive()

          guard await self.isCurrentConnection(token: connectionToken, task: webSocketTask) else { break }

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
          guard await self.isCurrentConnection(token: connectionToken, task: webSocketTask) else { break }
          log.trace("Error in receive loop")
          await handleError(error)
          break
        }
      }
    }
  }

  private func handleError(_ error: Error) async {
    // Capture error in Sentry
    log.error("WebSocket connection error", error: error)

    guard state != .idle else {
      log.trace("Ignoring error because state is idle")
      return
    }

    await scheduleReconnect(skipDelay: false, reason: .error)
  }

  // MARK: State transitions --------------------------------------------------

  private func connected() async {
    guard state != .connected else { return }
    state = .connected
    connectingStartTime = nil
    log.trace("Transport connected")
    // Stop watchdog when successfully connected - no longer need recovery checks
    stopWatchdog()
    Task { await _eventChannel.send(.connected) }
  }

  private func connecting() async {
    guard state != .connecting else { return }
    state = .connecting
    connectingStartTime = Date()
    // Restart watchdog when entering connecting state to detect if we get stuck
    startWatchdog()
    Task { await _eventChannel.send(.connecting) }
  }

  private func idle() async {
    guard state != .idle else { return }
    state = .idle
    connectingStartTime = nil
    log.trace("Transport stopping")
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

    // Double-check task is still valid after await points
    guard self.task === task else {
      log.trace("Ignoring didOpen - task became stale during execution")
      return
    }

    // Reset connection attempt number to 0 since we've successfully connected
    connectionAttemptNo = 0

    // Cancel the connection timeout task since we've successfully connected
    stopConnectionTimeout()

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
    // Only handle close events for the current task to prevent stale callbacks
    guard self.task === task else {
      log.trace("Ignoring didClose for stale WebSocket task")
      return
    }

    // Double-check task is still valid after await points
    guard self.task === task else {
      log.trace("Ignoring didClose - task became stale during execution")
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
