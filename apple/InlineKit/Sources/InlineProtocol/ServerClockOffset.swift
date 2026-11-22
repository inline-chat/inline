import Foundation

/// Server time minus this device's wall clock, learned from authenticated server messages and
/// shared by every Inline Protocol connection in the process, like MTProto's global time
/// difference. It is persisted, so a cached-key reconnect and a new handshake start from the
/// server's time instead of a wrong device clock; at worst the first send after a clock change
/// gets a 16 or 17 and the connection resyncs from it.
public final class InlineProtocolServerClockOffset: @unchecked Sendable {
  public static let shared = InlineProtocolServerClockOffset(
    defaults: .standard, key: "InlineProtocol.serverTimeOffsetMilliseconds"
  )

  /// A saved offset is rewritten only when it moves by at least this much, so sampling every
  /// server message does not write defaults on every record.
  static let persistThresholdMilliseconds: Int64 = 1_000

  private let lock = NSLock()
  private let defaults: UserDefaults
  private let key: String
  private var loaded = false
  private var offset: Int64?
  private var persisted: Int64?

  init(defaults: UserDefaults, key: String) {
    self.defaults = defaults
    self.key = key
  }

  /// The learned offset, or nil before any connection in this process or a previous launch
  /// sampled the server.
  public var offsetMilliseconds: Int64? {
    lock.withLock {
      loadIfNeeded()
      return offset
    }
  }

  /// The estimated server time now: the wall clock plus the learned offset.
  func estimatedServerUnixMilliseconds(wallMilliseconds: Int64 = wallClockMilliseconds()) -> Int64 {
    wallMilliseconds + (offsetMilliseconds ?? 0)
  }

  /// Records an authenticated server time sample taken at `wallMilliseconds` on this device.
  func record(serverUnixMilliseconds: Int64, wallMilliseconds: Int64 = wallClockMilliseconds()) {
    let value = serverUnixMilliseconds - wallMilliseconds
    lock.withLock {
      loadIfNeeded()
      offset = value
      if let persisted, abs(persisted - value) < Self.persistThresholdMilliseconds { return }
      persisted = value
      defaults.set(NSNumber(value: value), forKey: key)
    }
  }

  /// Forgets the offset in memory and on disk.
  public func reset() {
    lock.withLock {
      loaded = true
      offset = nil
      persisted = nil
      defaults.removeObject(forKey: key)
    }
  }

  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    if let number = defaults.object(forKey: key) as? NSNumber {
      offset = number.int64Value
      persisted = offset
    }
  }

  static func wallClockMilliseconds() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
  }
}
