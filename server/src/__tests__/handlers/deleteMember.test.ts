import { describe, expect, test, beforeEach } from "bun:test"
import { deleteMemberHandler } from "../../realtime/handlers/space.deleteMember"
import { setupTestLifecycle, testUtils } from "../setup"
import { db, schema } from "../../db"
import type { HandlerContext } from "../../realtime/types"
import type { DeleteMemberInput } from "@in/protocol/core"
import { and, eq } from "drizzle-orm"
import type { DbSpace, DbUser } from "@in/server/db/schema"

describe("deleteMemberHandler", () => {
  setupTestLifecycle()

  let adminUser: DbUser
  let memberUser: DbUser
  let space: DbSpace
  let handlerContext: HandlerContext

  beforeEach(async () => {
    // Create users
    adminUser = (await testUtils.createUser("admin@example.com"))!
    memberUser = (await testUtils.createUser("member@example.com"))!

    // Create space
    space = (await testUtils.createSpace("Delete Member Test Space"))!

    // Add members: admin (owner) and regular member
    await db
      .insert(schema.members)
      .values({
        userId: adminUser.id,
        spaceId: space.id,
        role: "owner" as const,
      })
      .execute()

    await db
      .insert(schema.members)
      .values({
        userId: memberUser.id,
        spaceId: space.id,
        role: "member" as const,
      })
      .execute()

    // Prepare handler context for admin user
    handlerContext = {
      userId: adminUser.id,
      sessionId: 456,
      connectionId: "test-connection",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }
  })

  test("should delete a member from space and return updates", async () => {
    const input: DeleteMemberInput = {
      spaceId: BigInt(space.id),
      userId: BigInt(memberUser.id),
    }

    const result = await deleteMemberHandler(input, handlerContext)

    expect(result.updates).toBeDefined()
    expect(result.updates.length).toBeGreaterThan(0)

    const deleteUpdate = result.updates.find((u) => u.update?.oneofKind === "spaceMemberDelete")
    expect(deleteUpdate).toBeDefined()

    const spaceMemberDelete = (deleteUpdate!.update as any).spaceMemberDelete
    expect(spaceMemberDelete.userId).toBe(BigInt(memberUser.id))
    expect(spaceMemberDelete.spaceId).toBe(BigInt(space.id))

    let membersMatching = await db
      .select()
      .from(schema.members)
      .where(and(eq(schema.members.userId, memberUser.id), eq(schema.members.spaceId, space.id)))
    expect(membersMatching.length).toBe(0)
  })
})
