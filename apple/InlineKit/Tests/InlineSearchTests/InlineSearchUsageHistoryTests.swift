import Foundation
import Testing

@testable import InlineKit
@testable import InlineSearch

@Suite("Inline search usage history")
struct InlineSearchUsageHistoryTests {
  @Test("usage learning survives persistence and remains account scoped")
  func persistenceAndAccountScope() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let preferredPeer = Peer.user(id: 20)
    var history = InlineSearchUsageHistory()

    history.recordSwitch(to: preferredPeer, accountID: "account-a", now: now)
    history.recordSelection(of: preferredPeer, query: "de \t na", accountID: "account-a", now: now)

    let data = try JSONEncoder().encode(history)
    var restored = try JSONDecoder().decode(InlineSearchUsageHistory.self, from: data)
    let fullQuerySignal = try #require(
      restored.rankingSignals(for: "dena", accountID: "account-a", now: now)[preferredPeer]
    )
    let prefixSignal = try #require(
      restored.rankingSignals(for: "de", accountID: "account-a", now: now)[preferredPeer]
    )

    #expect(fullQuerySignal.switchFrecency > 0)
    #expect(fullQuerySignal.queryAffinity > 0)
    #expect(prefixSignal.queryAffinity > 0)
    #expect(restored.rankingSignals(for: "dena", accountID: "account-b", now: now).isEmpty)

    let didClear = restored.clear(accountID: "account-a")
    #expect(didClear)
    #expect(restored.rankingSignals(for: "dena", accountID: "account-a", now: now).isEmpty)
  }

  @Test("stale usage is pruned when new activity is recorded")
  func staleUsagePruning() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let stalePeer = Peer.thread(id: 30)
    let currentPeer = Peer.thread(id: 31)
    var history = InlineSearchUsageHistory()

    history.recordSwitch(
      to: stalePeer,
      accountID: "account",
      now: now.addingTimeInterval(-181 * 86_400)
    )
    history.recordSwitch(to: currentPeer, accountID: "account", now: now)

    let signals = history.rankingSignals(for: "", accountID: "account", now: now)
    #expect(signals[stalePeer] == nil)
    #expect(signals[currentPeer]?.switchFrecency == 1)
  }

  @Test("peer usage remains bounded to the most recent destinations")
  func peerUsageIsBounded() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var history = InlineSearchUsageHistory()

    for id in 1...550 {
      history.recordSwitch(
        to: .user(id: Int64(id)),
        accountID: "account",
        now: now.addingTimeInterval(TimeInterval(id))
      )
    }

    let signals = history.rankingSignals(
      for: "",
      accountID: "account",
      now: now.addingTimeInterval(550)
    )
    #expect(signals.count == 500)
    #expect(signals[.user(id: 1)] == nil)
    #expect(signals[.user(id: 550)] != nil)
  }
}
