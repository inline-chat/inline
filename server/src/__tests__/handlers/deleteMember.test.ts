import { describe, expect, test, beforeEach } from "bun:test"
import { deleteMemberHandler } from "../../realtime/handlers/space.deleteMember"
import { setupTestLifecycle, testUtils } from "../setup"
import { db, schema } from "../../db"
import type { HandlerContext } from "../../realtime/types"
import type { DeleteMemberInput } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import type { DbSpace, DbUser } from "@in/server/db/schema"
import { createGridRoom, getGrid, joinGridRoom } from "@in/server/functions/grid"
import { toggleSpaceGrid } from "@in/server/functions/space.settings"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"

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

    const spaceMemberDelete =
      deleteUpdate?.update?.oneofKind === "spaceMemberDelete"
        ? deleteUpdate.update.spaceMemberDelete
        : undefined
    expect(spaceMemberDelete?.userId).toBe(BigInt(memberUser.id))
    expect(spaceMemberDelete?.spaceId).toBe(BigInt(space.id))

    let membersMatching = await db
      .select()
      .from(schema.members)
      .where(and(eq(schema.members.userId, memberUser.id), eq(schema.members.spaceId, space.id)))
    expect(membersMatching.length).toBe(0)
  })

  test("immediately removes the former member from Space fanout", async () => {
    connectionManager.subscribeToSpace(memberUser.id, space.id)
    expect(connectionManager.getSpaceUserIds(space.id)).toContain(memberUser.id)

    await deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(memberUser.id) },
      handlerContext,
    )

    expect(connectionManager.getSpaceUserIds(space.id)).not.toContain(memberUser.id)
  })

  test("does not report failure when the post-commit access-revoked push fails", async () => {
    const memberSession = await testUtils.createSessionForUser(memberUser.id)
    const connectionId = `failing-grid-revocation-${memberUser.id}`
    let sendCount = 0
    const ws = {
      id: connectionId,
      close: () => {},
      subscribe: () => {},
      raw: {
        sendBinary: () => {
          sendCount += 1
          if (sendCount === 1) {
            throw new Error("socket closed during Grid revocation")
          }
        },
      },
    } as unknown as Parameters<typeof connectionManager.addConnection>[0]
    connectionManager.addConnection(ws, ConnVersion.REALTIME_V1)
    connectionManager.authenticateConnection(connectionId, memberUser.id, memberSession.session.id)

    try {
      await expect(
        deleteMemberHandler(
          { spaceId: BigInt(space.id), userId: BigInt(memberUser.id) },
          handlerContext,
        ),
      ).resolves.toBeDefined()

      const membership = await db
        .select()
        .from(schema.members)
        .where(and(eq(schema.members.userId, memberUser.id), eq(schema.members.spaceId, space.id)))
      expect(membership).toEqual([])
    } finally {
      connectionManager.removeConnection(connectionId)
    }
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

  test("revokes active Grid presence and reconciles the remaining room", async () => {
    const adminSession = await testUtils.createSessionForUser(adminUser.id)
    const memberSession = await testUtils.createSessionForUser(memberUser.id)
    const adminContext = testUtils.functionContext({
      userId: adminUser.id,
      sessionId: adminSession.session.id,
    })
    const memberContext = testUtils.functionContext({
      userId: memberUser.id,
      sessionId: memberSession.session.id,
    })
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, adminContext)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, adminContext)
    const roomID = created.grids[0]!.rooms[0]!.id
    await joinGridRoom({ roomId: roomID }, memberContext)

    await deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(memberUser.id) },
      handlerContext,
    )

    const presence = await db
      .select()
      .from(schema.gridPresence)
      .where(eq(schema.gridPresence.userId, memberUser.id))
    expect(presence).toEqual([])
    const revocations = await db
      .select()
      .from(schema.gridProviderEffects)
      .where(
        and(
          eq(schema.gridProviderEffects.kind, "revoke_participant"),
          eq(schema.gridProviderEffects.userId, memberUser.id),
        ),
      )
    expect(revocations).toHaveLength(1)
    const grid = await getGrid({ spaceId: BigInt(space.id) }, adminContext)
    expect(grid.grid?.rooms[0]?.avatars.map((avatar) => avatar.user?.id)).toEqual([BigInt(adminUser.id)])
    expect(grid.grid?.rooms[0]?.connection).toBeUndefined()
  })

  test("rolls Grid presence and provider revocation back when member deletion fails", async () => {
    const adminSession = await testUtils.createSessionForUser(adminUser.id)
    const memberSession = await testUtils.createSessionForUser(memberUser.id)
    const adminContext = testUtils.functionContext({
      userId: adminUser.id,
      sessionId: adminSession.session.id,
    })
    const memberContext = testUtils.functionContext({
      userId: memberUser.id,
      sessionId: memberSession.session.id,
    })
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, adminContext)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, adminContext)
    await joinGridRoom({ roomId: created.grids[0]!.rooms[0]!.id }, memberContext)

    // Model an inconsistent pre-existing row so the handler reaches the Grid
    // cleanup and then discovers that the membership no longer exists.
    await db
      .delete(schema.members)
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, memberUser.id)))

    await expect(
      deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(memberUser.id) },
        handlerContext,
      ),
    ).rejects.toThrow()

    const presence = await db
      .select()
      .from(schema.gridPresence)
      .where(eq(schema.gridPresence.userId, memberUser.id))
    expect(presence).toHaveLength(1)
    const revocations = await db
      .select()
      .from(schema.gridProviderEffects)
      .where(eq(schema.gridProviderEffects.userId, memberUser.id))
    expect(revocations).toEqual([])
  })
})
