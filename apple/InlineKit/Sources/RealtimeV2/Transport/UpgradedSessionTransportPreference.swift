import Foundation
import InlineProtocol

/// Operator rollback lever for sessions that kept their bearer after a V3 upgrade. Every
/// connection open carries the server's current choice, and persisting it lets a cold start honor
/// a rollback before its first connection. Sessions without a bearer have no V2 path and ignore it.
public struct UpgradedSessionTransportPreference: Sendable {
  let prefersLegacy: @Sendable () -> Bool
  let record: @Sendable (_ prefersLegacy: Bool) -> Void

  init(
    prefersLegacy: @escaping @Sendable () -> Bool,
    record: @escaping @Sendable (_ prefersLegacy: Bool) -> Void
  ) {
    self.prefersLegacy = prefersLegacy
    self.record = record
  }

  /// Use the app group suite so app extensions follow the same rollback.
  public static func stored(in defaults: UserDefaults) -> Self {
    nonisolated(unsafe) let defaults = defaults
    return Self(
      prefersLegacy: { defaults.bool(forKey: storageKey) },
      record: { defaults.set($0, forKey: storageKey) }
    )
  }

  static let storageKey = "realtime.upgradedSessionTransport.prefersLegacy"

  /// An open without the field comes from a server that predates the lever, so V3 is allowed.
  static func prefersLegacy(_ open: ConnectionOpen) -> Bool {
    open.hasUpgradedSessionTransport && open.upgradedSessionTransport == .legacy
  }
}
