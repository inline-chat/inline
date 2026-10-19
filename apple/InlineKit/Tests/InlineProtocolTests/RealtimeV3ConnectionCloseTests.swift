import Foundation
import Network
import Testing
@testable import InlineProtocol

@Suite("Realtime V3 connection close", .serialized)
struct RealtimeV3ConnectionCloseTests {
  /// A local proxy whose upstream stalls keeps the socket open but stops draining it. A system
  /// WebSocket send then never completes and ignores task cancellation, so close must abort the
  /// wire before it waits for that send; otherwise transport stop never returns and the
  /// connection owner stays on "Connecting..." (macOS, 2026-10-19).
  @Test("close returns while a wire send is stalled behind a peer that stopped reading")
  func closeEndsStalledWireSend() async throws {
    let server = try StalledReaderWebSocketServer()
    defer { server.cancel() }
    let url = try #require(URL(string: "ws://127.0.0.1:\(try server.port)/realtime/v3"))
    let key = (0 ..< 256).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    let authorization = try InlineProtocolAuthorization(
      key: key,
      keyID: InlineSecureTransport.authKeyID(key),
      serverSalt: 1,
      temporary: false,
      expiresAt: nil
    )
    let connection = try await InlineProtocolV3Connection.connect(.reconnect(url: url, authorization: authorization))

    var request = RealtimeV3Request()
    request.rpc = .with {
      $0.method = .sendMessage
      $0.input = .sendMessage(.with { $0.message = String(repeating: "x", count: 900_000) })
    }
    let progress = WriteProgress()
    let writer = Task {
      for _ in 0 ..< 32 {
        try await connection.beginInvoke(request) { _ in }
        await progress.advance()
      }
    }

    #expect(await progress.stalls(for: .milliseconds(1_500), within: .seconds(20)))
    let admittedBeforeStall = await progress.count
    #expect(admittedBeforeStall < 32)

    let closed = await completes(within: .seconds(5)) { await connection.close() }
    #expect(closed, "close stayed blocked behind a stalled wire send after \(admittedBeforeStall) writes")

    // Closing the peer ends the stalled send, so an unfixed close cannot leak past the test.
    server.cancel()
    _ = try? await writer.value
  }
}

private actor WriteProgress {
  private(set) var count = 0
  private var lastAdvance = ContinuousClock.now

  func advance() {
    count += 1
    lastAdvance = .now
  }

  /// True once no write has completed for `quiet` after at least one write completed.
  func stalls(for quiet: Duration, within timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if count > 0, lastAdvance.duration(to: .now) >= quiet { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }
}

private actor CompletionFlag {
  private(set) var done = false
  func finish() { done = true }
}

private func completes(within timeout: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
  let flag = CompletionFlag()
  Task {
    await work()
    await flag.finish()
  }
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await flag.done { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return await flag.done
}

private enum StalledReaderWebSocketServerError: Error {
  case listenerFailed(String)
  case missingPort
}

/// Completes the WebSocket upgrade and never reads, like a proxy whose upstream stalled.
private final class StalledReaderWebSocketServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "chat.inline.v3-close-test")
  private let lock = NSLock()
  private var connections: [NWConnection] = []

  var port: UInt16 {
    get throws {
      guard let rawValue = listener.port?.rawValue else {
        throw StalledReaderWebSocketServerError.missingPort
      }
      return rawValue
    }
  }

  init() throws {
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
    listener = try NWListener(using: parameters, on: .any)
    listener.newConnectionHandler = { [weak self, queue] connection in
      self?.lock.withLock { self?.connections.append(connection) }
      connection.start(queue: queue)
    }
    let ready = DispatchSemaphore(value: 0)
    let failure = LockedFailure()
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        ready.signal()
      case let .failed(error):
        failure.set(String(describing: error))
        ready.signal()
      default:
        break
      }
    }
    listener.start(queue: queue)
    ready.wait()
    if let message = failure.value {
      listener.cancel()
      throw StalledReaderWebSocketServerError.listenerFailed(message)
    }
  }

  func cancel() {
    listener.cancel()
    let active = lock.withLock {
      defer { connections.removeAll() }
      return connections
    }
    for connection in active {
      connection.cancel()
    }
  }
}

private final class LockedFailure: @unchecked Sendable {
  private let lock = NSLock()
  private var message: String?

  var value: String? { lock.withLock { message } }

  func set(_ value: String) {
    lock.withLock { message = value }
  }
}
