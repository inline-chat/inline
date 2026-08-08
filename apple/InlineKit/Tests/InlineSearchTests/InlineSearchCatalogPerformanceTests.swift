import Foundation
import Testing

@testable import InlineKit
@testable import InlineSearch

@Suite("Inline search catalog performance", .serialized)
struct InlineSearchCatalogPerformanceTests {
  @Test("projects a bounded result snapshot", arguments: [100, 1_000, 10_000])
  func boundedProjection(candidateCount: Int) async {
    let catalog = InlineSearchChatCatalog()
    await catalog.replace(Self.snapshots(count: candidateCount))

    let clock = ContinuousClock()
    let start = clock.now
    let projection = await catalog.project(
      query: "target",
      usage: [:],
      currentPeer: nil,
      scope: InlineSearchScope(includeArchived: true),
      chatLimit: 20
    )
    let duration = start.duration(to: clock.now)

    print("InlineSearchChatCatalog candidates=\(candidateCount) duration=\(duration)")
    #expect(projection.chats.count == min(candidateCount, 20))
  }

  @Test("bounded projection keeps the globally best ranked matches")
  func boundedProjectionRanking() async {
    let candidateCount = 50
    let catalog = InlineSearchChatCatalog()
    await catalog.replace(Self.snapshots(count: candidateCount))
    let usage = Dictionary(uniqueKeysWithValues: (1...candidateCount).map { index in
      (
        Peer.user(id: Int64(100_000 + index)),
        InlineSearchUsageSignal(queryAffinity: Double(index))
      )
    })

    let projection = await catalog.project(
      query: "target",
      usage: usage,
      currentPeer: nil,
      scope: InlineSearchScope(includeArchived: true),
      chatLimit: 20
    )

    let expected = (31...50).reversed().map { Peer.user(id: Int64(100_000 + $0)) }
    #expect(projection.chats.map(\.peer) == expected)
  }

  private static func snapshots(count: Int) -> [HomeChatListItemSnapshot] {
    (1...count).map { index in
      let userID = Int64(100_000 + index)
      var dialog = Dialog(optimisticForUserId: userID)
      dialog.open = true
      dialog.openedDate = Date(timeIntervalSince1970: TimeInterval(index))
      let user = User(
        id: userID,
        email: "target-\(index)@example.com",
        firstName: "Target",
        lastName: "Person \(index)",
        username: "target\(index)"
      )
      return HomeChatListItemSnapshot(
        item: HomeChatItem(
          dialog: dialog,
          user: UserInfo(user: user),
          chat: nil,
          lastMessage: nil,
          space: nil
        )
      )
    }
  }
}
