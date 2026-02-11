import { describe, expect, test, beforeEach } from "bun:test"
import { deleteMemberHandler } from "../../realtime/handlers/space.deleteMember"
import { setupTestLifecycle, testUtils } from "../setup"
import { db, schema } from "../../db"
import type { HandlerContext } from "../../realtime/types"
import type { DeleteMemberInput } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import type { DbSpace, DbUser } from "@in/server/db/schema"

describe("deleteMemberHandler", () => {
  setupTestLifecycle()

  let adminUser: DbUser
  let memberUser: DbUser
  let space: DbSpace
  let handlerContext: HandlerContext
  let privateThreadId: number

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

    // Create a private thread in the space with both users as participants + dialogs
    const [thread] = await db
      .insert(schema.chats)
      .values({
        type: "thread" as const,
        title: "Private Thread",
        spaceId: space.id,
        publicThread: false,
      })
      .returning()

    privateThreadId = thread!.id

    await db
      .insert(schema.chatParticipants)
      .values([
        { chatId: privateThreadId, userId: adminUser.id },
        { chatId: privateThreadId, userId: memberUser.id },
      ])
      .execute()

    await db
      .insert(schema.dialogs)
      .values([
        { chatId: privateThreadId, userId: adminUser.id, spaceId: space.id },
        { chatId: privateThreadId, userId: memberUser.id, spaceId: space.id },
      ])
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

  test("removes user from private threads and dialogs in the space", async () => {
    const input: DeleteMemberInput = {
      spaceId: BigInt(space.id),
      userId: BigInt(memberUser.id),
    }

    await deleteMemberHandler(input, handlerContext)

    const participants = await db
      .select()
      .from(schema.chatParticipants)
      .where(
        and(eq(schema.chatParticipants.chatId, privateThreadId), eq(schema.chatParticipants.userId, memberUser.id)),
      )
    expect(participants.length).toBe(0)

    const memberDialogs = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, privateThreadId), eq(schema.dialogs.userId, memberUser.id)))
    expect(memberDialogs.length).toBe(0)

    const adminDialogs = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, privateThreadId), eq(schema.dialogs.userId, adminUser.id)))
    expect(adminDialogs.length).toBe(1)
  })
})
