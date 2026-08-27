import Foundation
import Testing

@testable import InlineKit
@testable import InlineProtocol
import RealtimeV2

@Suite("Space Join Transactions")
struct SpaceJoinTransactionsTests {
  @Test("encodes private join without opting into durable credential storage")
  func privateJoinInput() {
    let token = "iv1_\(String(repeating: "a", count: 43))"
    let transaction = JoinSpaceByInviteTokenTransaction(token: token)

    guard case let .joinSpaceByInviteToken(input) = transaction.input(from: transaction.context) else {
      Issue.record("Expected private join input")
      return
    }
    #expect(input.token == token)
    guard case let .mutation(config) = transaction.type else {
      Issue.record("Expected a mutation")
      return
    }
    #expect(config.transient)
  }

  @Test("encodes invite-link administration")
  func inviteLinkInputs() {
    let get = GetSpaceInviteLinkTransaction(spaceId: 42)
    guard case let .getSpaceInviteLink(getInput) = get.input(from: get.context) else {
      Issue.record("Expected get invite link input")
      return
    }
    #expect(getInput.spaceID == 42)

    let set = SetSpaceInviteLinkEnabledTransaction(spaceId: 42, enabled: true)
    guard case let .setSpaceInviteLinkEnabled(setInput) = set.input(from: set.context) else {
      Issue.record("Expected set invite link input")
      return
    }
    #expect(setInput.spaceID == 42)
    #expect(setInput.enabled)
  }

  @Test("registers invite-link administration transactions")
  func inviteLinkTransactionRegistry() throws {
    let get = GetSpaceInviteLinkTransaction(spaceId: 42)
    #expect(TransactionTypeRegistry.typeString(for: get) == "get_space_invite_link")
    let getData = try JSONEncoder().encode(get)
    #expect(
      TransactionTypeRegistry.typeString(
        for: try TransactionTypeRegistry.decodeTransaction(
          type: "get_space_invite_link",
          data: getData
        )
      ) == "get_space_invite_link"
    )

    let set = SetSpaceInviteLinkEnabledTransaction(spaceId: 42, enabled: true)
    #expect(TransactionTypeRegistry.typeString(for: set) == "set_space_invite_link_enabled")
  }

  @Test("encodes block and remove and keeps older queued removals compatible")
  func deleteMemberBlockJoinCompatibility() throws {
    let blocked = DeleteMemberTransaction(spaceId: 7, userId: 9, blockJoin: true)
    guard case let .deleteMember(blockedInput) = blocked.input(from: blocked.context) else {
      Issue.record("Expected delete member input")
      return
    }
    #expect(blockedInput.blockJoin)

    let olderJSON = Data(#"{"context":{"spaceId":7,"userId":9}}"#.utf8)
    let older = try JSONDecoder().decode(DeleteMemberTransaction.self, from: olderJSON)
    guard case let .deleteMember(olderInput) = older.input(from: older.context) else {
      Issue.record("Expected decoded delete member input")
      return
    }
    #expect(!olderInput.blockJoin)
  }
}
