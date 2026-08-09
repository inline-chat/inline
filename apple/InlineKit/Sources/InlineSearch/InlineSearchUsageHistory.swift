import CryptoKit
import Foundation
import InlineKit

public struct InlineSearchUsageHistory: Codable, Sendable {
  private var version = 1
  private var accounts: [String: AccountState] = [:]

  public init() {}

  public func rankingSignals(
    for query: String,
    accountID: String,
    now: Date = Date()
  ) -> [Peer: InlineSearchUsageSignal] {
    guard let account = accounts[accountID] else { return [:] }

    var values: [Peer: MutableSignal] = [:]
    for (peerKey, record) in account.peers {
      guard let peer = Self.peer(from: peerKey) else { continue }
      values[peer] = MutableSignal(
        switchFrecency: Self.decayedScore(
          count: record.count,
          lastUsedAt: record.lastUsedAt,
          now: now,
          halfLifeDays: 45
        ),
        queryAffinity: 0,
        lastOpenedAt: record.lastUsedAt
      )
    }

    for queryKey in Self.queryKeys(for: query) {
      guard let selections = account.queries[queryKey] else { continue }
      for (peerKey, record) in selections {
        guard let peer = Self.peer(from: peerKey) else { continue }
        var signal = values[peer] ?? MutableSignal()
        signal.queryAffinity += Self.decayedScore(
          count: record.count,
          lastUsedAt: record.lastUsedAt,
          now: now,
          halfLifeDays: 30
        )
        values[peer] = signal
      }
    }

    return values.mapValues { signal in
      InlineSearchUsageSignal(
        switchFrecency: signal.switchFrecency,
        queryAffinity: signal.queryAffinity,
        lastOpenedAt: signal.lastOpenedAt
      )
    }
  }

  public mutating func recordSwitch(
    to peer: Peer,
    accountID: String,
    now: Date = Date()
  ) {
    var account = accounts[accountID] ?? AccountState()
    let peerKey = peer.toString()
    var record = account.peers[peerKey] ?? UsageRecord()
    record.count = min(record.count + 1, 100_000)
    record.lastUsedAt = now
    account.peers[peerKey] = record
    accounts[accountID] = Self.pruned(account, now: now)
  }

  public mutating func recordSelection(
    of peer: Peer,
    query: String,
    accountID: String,
    now: Date = Date()
  ) {
    let queryKeys = Self.queryKeys(for: query)
    guard queryKeys.isEmpty == false else { return }

    var account = accounts[accountID] ?? AccountState()
    let peerKey = peer.toString()
    for queryKey in queryKeys {
      var selections = account.queries[queryKey] ?? [:]
      var record = selections[peerKey] ?? UsageRecord()
      record.count = min(record.count + 1, 10_000)
      record.lastUsedAt = now
      selections[peerKey] = record
      account.queries[queryKey] = selections
    }
    accounts[accountID] = Self.pruned(account, now: now)
  }

  @discardableResult
  public mutating func clear(accountID: String) -> Bool {
    accounts.removeValue(forKey: accountID) != nil
  }

  private static func queryKeys(for query: String) -> [String] {
    guard let prepared = InlineSearchMatcher.prepare(query) else { return [] }

    var rawKeys = ["query:\(prepared.normalized)"]
    let maximumPrefixLength = min(prepared.compact.count, 8)
    if maximumPrefixLength >= 2 {
      for length in 2...maximumPrefixLength {
        rawKeys.append("compact:\(prepared.compact.prefix(length))")
      }
    }

    return Array(Set(rawKeys.map(hash))).sorted()
  }

  private static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func decayedScore(
    count: Int,
    lastUsedAt: Date?,
    now: Date,
    halfLifeDays: Double
  ) -> Double {
    guard count > 0, let lastUsedAt else { return 0 }
    let ageDays = max(0, now.timeIntervalSince(lastUsedAt) / 86_400)
    let decay = pow(0.5, ageDays / halfLifeDays)
    return log2(Double(count) + 1) * decay
  }

  private static func pruned(_ account: AccountState, now: Date) -> AccountState {
    let cutoff = now.addingTimeInterval(-180 * 86_400)
    let peers = account.peers
      .filter { ($0.value.lastUsedAt ?? .distantPast) >= cutoff }
      .sorted { ($0.value.lastUsedAt ?? .distantPast) > ($1.value.lastUsedAt ?? .distantPast) }
      .prefix(500)

    let queries = account.queries
      .compactMap { key, records -> (String, [String: UsageRecord], Date)? in
        let recent = records
          .filter { ($0.value.lastUsedAt ?? .distantPast) >= cutoff }
          .sorted { ($0.value.lastUsedAt ?? .distantPast) > ($1.value.lastUsedAt ?? .distantPast) }
          .prefix(12)
        guard let newest = recent.first?.value.lastUsedAt else { return nil }
        return (key, Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) }), newest)
      }
      .sorted { $0.2 > $1.2 }
      .prefix(256)

    return AccountState(
      peers: Dictionary(uniqueKeysWithValues: peers.map { ($0.key, $0.value) }),
      queries: Dictionary(uniqueKeysWithValues: queries.map { ($0.0, $0.1) })
    )
  }

  private static func peer(from value: String) -> Peer? {
    if value.hasPrefix("user_"), let id = Int64(value.dropFirst("user_".count)) {
      return .user(id: id)
    }
    if value.hasPrefix("thread_"), let id = Int64(value.dropFirst("thread_".count)) {
      return .thread(id: id)
    }
    return nil
  }

  private struct MutableSignal: Sendable {
    var switchFrecency: Double = 0
    var queryAffinity: Double = 0
    var lastOpenedAt: Date?
  }

  private struct AccountState: Codable, Sendable {
    var peers: [String: UsageRecord] = [:]
    var queries: [String: [String: UsageRecord]] = [:]
  }

  private struct UsageRecord: Codable, Sendable {
    var count = 0
    var lastUsedAt: Date?
  }
}
