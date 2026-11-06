import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Owned agent grants")
struct OwnedAgentGrantsTests {
  private static let bot: Int64 = 900
  private static let owner: Int64 = 1

  private static func grant(
    _ userID: Int64,
    _ ops: [AgentGrantOperation],
    revision: Int64,
    bot: Int64 = bot
  ) -> AgentGrant {
    .with {
      $0.botUserID = bot
      $0.userID = userID
      $0.operations = ops
      $0.revision = revision
    }
  }

  private static func list(_ grants: [AgentGrant], revision: Int64, owner: Int64 = owner) -> ListAgentGrantsResult {
    .with {
      $0.grants = grants
      $0.revision = revision
      $0.ownerUserID = owner
    }
  }

  @Test("snapshot keeps only active grants for its bot")
  func snapshot() {
    let other = Self.grant(3, [.invoke], revision: 4, bot: 901)
    let owned = OwnedAgentGrants(
      Self.list([Self.grant(2, [.invoke, .steer], revision: 5), Self.grant(4, [.unspecified], revision: 6), other], revision: 7),
      botUserID: Self.bot
    )
    #expect(owned.userIDs == [2])
    #expect(owned.hasGrant(userID: 2))
    #expect(!owned.hasGrant(userID: 3))
    #expect(owned.revision == 7)
  }

  @Test("updates at or below the snapshot or a person's last change are stale")
  func staleUpdates() {
    var owned = OwnedAgentGrants(Self.list([Self.grant(2, [.invoke], revision: 5)], revision: 7), botUserID: Self.bot)
    let atSnapshot = owned.apply(userID: 2, operations: [], revision: 7)
    #expect(!atSnapshot)
    #expect(owned.hasGrant(userID: 2))

    let removed = owned.apply(userID: 2, operations: [], revision: 9)
    #expect(removed)
    #expect(!owned.hasGrant(userID: 2))
    // A late echo of an earlier add never resurrects a removed grant.
    let lateEcho = owned.apply(userID: 2, operations: [.invoke], revision: 8)
    #expect(!lateEcho)
    #expect(!owned.hasGrant(userID: 2))

    let added = owned.apply(userID: 3, operations: [.invoke, .steer], revision: 10)
    #expect(added)
    #expect(owned.userIDs == [3])
    #expect(owned.revision == 10)
  }

  @Test("badge bot follows participant order and keeps a still-present choice")
  func selection() {
    let owned = [
      Self.bot: OwnedAgentGrants(Self.list([], revision: 0), botUserID: Self.bot),
      901: OwnedAgentGrants(Self.list([], revision: 0), botUserID: 901),
    ]
    let bots = OwnedAgentGrants.ownedBotIDs(among: [902, 901, Self.bot, 901], owned: owned)
    #expect(bots == [901, Self.bot])
    #expect(OwnedAgentGrants.selectedBotID(preferred: nil, among: bots) == 901)
    #expect(OwnedAgentGrants.selectedBotID(preferred: Self.bot, among: bots) == Self.bot)
    #expect(OwnedAgentGrants.selectedBotID(preferred: 902, among: bots) == 901)
    #expect(OwnedAgentGrants.selectedBotID(preferred: nil, among: []) == nil)
  }

  @Test("store keeps full lists only for bots the viewer owns")
  @MainActor
  func storeOwnership() {
    let store = AgentGrantStore()
    store.apply(Self.list([Self.grant(2, [.invoke], revision: 3)], revision: 3), botUserID: Self.bot, viewerUserID: Self.owner)
    #expect(store.ownedGrants(botUserID: Self.bot)?.userIDs == [2])
    #expect(store.access(botUserID: Self.bot)?.isOwner == true)

    store.apply(Self.list([Self.grant(2, [.invoke], revision: 3, bot: 901)], revision: 3), botUserID: 901, viewerUserID: 2)
    #expect(store.ownedGrants(botUserID: 901) == nil)
    #expect(store.access(botUserID: 901)?.operations == [.invoke])

    // Owner-side updates for other people amend the list.
    store.apply(UpdateAgentGrant.with {
      $0.botUserID = Self.bot
      $0.userID = 5
      $0.grant = Self.grant(5, [.invoke, .steer], revision: 4)
      $0.revision = 4
    }, viewerUserID: Self.owner)
    #expect(store.ownedGrants(botUserID: Self.bot)?.userIDs == [2, 5])

    store.apply(UpdateAgentGrant.with {
      $0.botUserID = Self.bot
      $0.userID = 2
      $0.revision = 5
    }, viewerUserID: Self.owner)
    #expect(store.ownedGrants(botUserID: Self.bot)?.userIDs == [5])

    // An older snapshot never replaces newer state.
    store.apply(Self.list([Self.grant(2, [.invoke], revision: 3)], revision: 3), botUserID: Self.bot, viewerUserID: Self.owner)
    #expect(store.ownedGrants(botUserID: Self.bot)?.userIDs == [5])

    store.removeAll()
    #expect(store.ownedGrants(botUserID: Self.bot) == nil)
  }
}
