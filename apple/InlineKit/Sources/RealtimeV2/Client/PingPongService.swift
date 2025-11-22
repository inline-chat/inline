import Foundation
import Logger
import Network

actor PingPongService {
  private let log = Log.scoped("RealtimeV2.PingPongService", level: .info)

  init() {}

  private weak var client: ProtocolClient?
  private var pingTask: Task<Void, Never>?

  private var pings: [UInt64: Date] = [:] // nonce -> timestamp
  private var recentLatenciesMs: [UInt32] = []

  /// Call when starting the client/transport
  func start() {
    log.debug("starting ping pong service")
    reset()
    pingTask = Task {
      while !Task.isCancelled {
        // check if we have a ping in flight, to reconnect if needed
        await checkConnection()

        // at an interval
        do {
          try await Task.sleep(for: getNextPingDelay())
          guard !Task.isCancelled else { break }
        } catch {
          log.error("Error sleeping: \(error)")
          continue
        }

        // send pings
        Task { await ping() }
      }
    }
  }

  /// Call when stopping the client/transport
  func stop() {
    log.debug("stopping ping pong service")
    reset()
    pingTask?.cancel()
    pingTask = nil
  }

  func configure(client: ProtocolClient) {
    self.client = client
  }

  /// Call when reconnected
  private func reset() {
    pings.removeAll()
    recentLatenciesMs.removeAll()
  }

  func ping() async {
    guard let client else { return }
    guard await client.state == .open else { return }

    let nonce = UInt64.random(in: 0 ... UInt64.max)
    log.debug("ping sent with nonce: \(nonce)")
    await client.sendPing(nonce: nonce)
    pings[nonce] = Date()
  }

  /// Called when a pong is received in Client.swift
  func pong(nonce: UInt64) {
    log.debug("pong received for nonce: \(nonce)")

    guard let pingDate = pings[nonce] else {
      log.trace("pong received for unknown ping nonce: \(nonce)")
      return
    }

    // remove the ping
    pings.removeValue(forKey: nonce)

    // calculate latency
    recordLatency(pingDate: pingDate)

    log.debug("avg latency: \(avgLatencyMs()) ms")
  }

  // MARK: - Helpers

  private func getNextPingDelay() -> Duration {
    // TODO: Detect cellular network/bad network conditions and use a higher interval
    if avgLatencyMs() > 2_000 {
      log.debug("avg latency is high, increasing ping interval")
      return .seconds(25)
    } else {
      return .seconds(10)
    }
  }

  private func checkConnection() async {
    guard let client else { return }

    // Only restart if connection assumes to be open
    guard await client.state == .open else { return }

    // Check if we have a ping in flight from last 30 seconds
    let pingsInFlight = pings.filter { $0.value.timeIntervalSinceNow > -30 }
    guard pingsInFlight.count > 0 else { return }

    // Trigger a reconnect
    await client.reconnect()
  }

  private func recordLatency(pingDate: Date) {
    let latency = Date().timeIntervalSince(pingDate)
    recentLatenciesMs.append(UInt32(latency * 1_000))
    if recentLatenciesMs.count > 10 {
      recentLatenciesMs.removeFirst()
    }
  }

  private func avgLatencyMs() -> UInt32 {
    // otherwise we'll divide by 0 and get a crash
    guard recentLatenciesMs.count > 0 else { return 0 }
    let sum = recentLatenciesMs.reduce(0, +)
    return sum / UInt32(recentLatenciesMs.count)
  }
}
