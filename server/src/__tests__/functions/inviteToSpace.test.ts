import { describe, test, expect } from "bun:test"
import { inviteToSpace } from "@in/server/functions/space.inviteToSpace"
import { testUtils, setupTestLifecycle } from "../setup"
import { Member_Role } from "@in/protocol/core"

function makeFunctionContext(userId: number) {
  return {
    currentUserId: userId,
    currentSessionId: 1,
  }
}

process.env["DEBUG"] = "1"
describe("inviteToSpace", () => {
  setupTestLifecycle()

  test("successfully invites a user by email", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Invite Space", ["owner@ex.com"])
    const owner = users[0]
    const input = {
      spaceId: BigInt(space.id),
      role: Member_Role.MEMBER,
      via: { oneofKind: "email" as const, email: "invitee@ex.com" },
    }
    const context = makeFunctionContext(owner.id)
    const result = await inviteToSpace(input, context)
    expect(result.user).toBeTruthy()
    expect(result.member).toBeTruthy()

    if (result.user && result.member) {
      expect(result.user.email).toBe("invitee@ex.com")
      expect(result.member.spaceId).toBe(BigInt(space.id))
    }
    expect(result.chat).toBeTruthy()
    expect(result.dialog).toBeTruthy()
  })

  test("throws error for invalid spaceId", async () => {
    const input = {
      spaceId: BigInt(-1),
      role: Member_Role.MEMBER,
      via: { oneofKind: "email" as const, email: "invitee@ex.com" },
    }
    const context = makeFunctionContext(1)
    await expect(inviteToSpace(input, context)).rejects.toThrow()
  })

  test("throws error when member tries to invite as admin", async () => {
    // Create space with a member (not owner)
    const { space, users } = await testUtils.createSpaceWithMembers("Member Space", ["member@ex.com"])
    const member = users[0]
    // Manually set role to 'member' if needed (depends on implementation)
    const input = {
      spaceId: BigInt(space.id),
      role: Member_Role.ADMIN,
      via: { oneofKind: "email" as const, email: "invitee2@ex.com" },
    }
    const context = makeFunctionContext(member.id)
    await expect(inviteToSpace(input, context)).rejects.toThrow()
  })
})
