import { describe, expect, spyOn, test } from "bun:test"
import { and, eq, inArray } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import type { HandlerContext as LegacyHandlerContext } from "@in/server/controllers/helpers"
import type { HandlerContext } from "@in/server/realtime/types"
import { handler as leaveSpace } from "@in/server/methods/leaveSpace"
import { handler as deleteSpace } from "@in/server/methods/deleteSpace"
import { deleteMemberHandler } from "@in/server/realtime/handlers/space.deleteMember"
import { addSpaceMember } from "@in/server/functions/space.addMember.shared"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { InlineError } from "@in/server/types/errors"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { setupTestLifecycle, testUtils } from "../setup"

const legacyContext = (userId: number): LegacyHandlerContext => ({
  currentUserId: userId,
  currentSessionId: 1,
  ip: "127.0.0.1",
})

const realtimeContext = (userId: number): HandlerContext => ({
  userId,
  sessionId: 1,
  connectionId: `membership-rules-${userId}`,
  sendRaw: () => {},
  sendRpcReply: () => {},
})

const createBot = async (name: string, creatorId: number) => {
  const [bot] = await db
    .insert(schema.users)
    .values({
      firstName: name,
      username: `${name.toLowerCase().replace(/\W/g, "_")}_bot`,
      bot: true,
      botCreatorId: creatorId,
      pendingSetup: false,
    })
    .returning()
  if (!bot) throw new Error("Failed to create bot")
  return bot
}

const memberUserIds = async (spaceId: number) =>
  (await db.select({ userId: schema.members.userId }).from(schema.members).where(eq(schema.members.spaceId, spaceId)))
    .map((row) => row.userId)
    .sort((left, right) => left - right)

const hasChatAccess = async (chatId: number, userId: number) => {
  const access = await db.transaction((tx) => getEffectiveChatAccessUserIds(tx, [chatId], { userIds: [userId] }))
  return access.get(chatId)?.has(userId) === true
}

describe("space membership rules", () => {
  setupTestLifecycle()

  test("an admin cannot remove an owner, but an owner can", async () => {
    const owner = await testUtils.createUser("rules-owner@example.com")
    const coOwner = await testUtils.createUser("rules-co-owner@example.com")
    const admin = await testUtils.createUser("rules-admin@example.com")
    const space = await testUtils.createSpace("Owner Target Rules")
    if (!space) throw new Error("Failed to create Space")
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: coOwner.id, role: "owner" },
      { spaceId: space.id, userId: admin.id, role: "admin" },
    ])

    await expect(
      deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(owner.id), blockJoin: false },
        realtimeContext(admin.id),
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.SPACE_OWNER_REQUIRED })
    expect(await memberUserIds(space.id)).toContain(owner.id)

    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      await deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(coOwner.id), blockJoin: false },
        realtimeContext(owner.id),
      )
    } finally {
      push.mockRestore()
    }
    expect(await memberUserIds(space.id)).not.toContain(coOwner.id)
  })

  test("leaving drops private-thread access so rejoining does not restore it", async () => {
    const owner = await testUtils.createUser("rules-leave-owner@example.com")
    const leaver = await testUtils.createUser("rules-leave-member@example.com")
    const space = await testUtils.createSpace("Leave Then Rejoin")
    if (!space) throw new Error("Failed to create Space")
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: leaver.id, role: "member" },
    ])
    const privateThread = await testUtils.createChat(space.id, "Private thread", "thread", false)
    if (!privateThread) throw new Error("Failed to create thread")
    await db.insert(schema.chatParticipants).values([
      { chatId: privateThread.id, userId: owner.id },
      { chatId: privateThread.id, userId: leaver.id },
    ])
    await db.insert(schema.dialogs).values({ chatId: privateThread.id, userId: leaver.id, spaceId: space.id })
    expect(await hasChatAccess(privateThread.id, leaver.id)).toBe(true)

    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      await leaveSpace({ spaceId: space.id }, legacyContext(leaver.id))

      // The leaver is told about the lost chat, like an admin removal.
      const removedFromChat = push.mock.calls.some(([userId, updates]) =>
        userId === leaver.id
        && updates.some((update) =>
          update.update.oneofKind === "userRemovedFromChat"
          && update.update.userRemovedFromChat.chatId === BigInt(privateThread.id),
        ),
      )
      expect(removedFromChat).toBe(true)

      await addSpaceMember({
        spaceId: space.id,
        actorUserId: owner.id,
        target: { kind: "userId", userId: leaver.id },
        admission: "manageMembers",
      })
    } finally {
      push.mockRestore()
    }

    expect(await memberUserIds(space.id)).toContain(leaver.id)
    expect(await hasChatAccess(privateThread.id, leaver.id)).toBe(false)
    expect(await db.select().from(schema.dialogs).where(and(
      eq(schema.dialogs.chatId, privateThread.id),
      eq(schema.dialogs.userId, leaver.id),
    ))).toEqual([])
    expect(await hasChatAccess(privateThread.id, owner.id)).toBe(true)
  })

  test("a departing member's bots leave the Space with them, on leave and on removal", async () => {
    const owner = await testUtils.createUser("rules-bots-owner@example.com")
    const leaver = await testUtils.createUser("rules-bots-leaver@example.com")
    const removed = await testUtils.createUser("rules-bots-removed@example.com")
    const space = await testUtils.createSpace("Departing Bots")
    if (!space) throw new Error("Failed to create Space")
    const leaverBot = await createBot("Leaver Helper", leaver.id)
    const removedBot = await createBot("Removed Helper", removed.id)
    const ownerBot = await createBot("Owner Helper", owner.id)
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: leaver.id, role: "member" },
      { spaceId: space.id, userId: removed.id, role: "member" },
      { spaceId: space.id, userId: leaverBot.id, role: "member" },
      { spaceId: space.id, userId: removedBot.id, role: "member" },
      { spaceId: space.id, userId: ownerBot.id, role: "member" },
    ])
    const privateThread = await testUtils.createChat(space.id, "Bot thread", "thread", false)
    if (!privateThread) throw new Error("Failed to create thread")
    await db.insert(schema.chatParticipants).values([
      { chatId: privateThread.id, userId: owner.id },
      { chatId: privateThread.id, userId: leaverBot.id },
      { chatId: privateThread.id, userId: removedBot.id },
    ])

    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      await leaveSpace({ spaceId: space.id }, legacyContext(leaver.id))
      expect(await memberUserIds(space.id)).toEqual(
        [owner.id, removed.id, removedBot.id, ownerBot.id].sort((left, right) => left - right),
      )

      const result = await deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(removed.id), blockJoin: false },
        realtimeContext(owner.id),
      )
      // The actor's reply carries one sequenced removal per departing member.
      const replyRemovals = result.updates.flatMap((update) =>
        update.update.oneofKind === "spaceMemberDelete" ? [Number(update.update.spaceMemberDelete.userId)] : [],
      )
      expect(replyRemovals).toEqual([removed.id, removedBot.id])

      // Remaining members see each bot's removal too.
      const ownerSawBotRemoval = push.mock.calls.some(([userId, updates]) =>
        userId === owner.id
        && updates.some((update) =>
          update.update.oneofKind === "spaceMemberDelete"
          && update.update.spaceMemberDelete.userId === BigInt(leaverBot.id)
          && update.seq !== undefined,
        ),
      )
      expect(ownerSawBotRemoval).toBe(true)
    } finally {
      push.mockRestore()
    }

    expect(await memberUserIds(space.id)).toEqual([owner.id, ownerBot.id].sort((left, right) => left - right))
    expect(await db.select().from(schema.chatParticipants).where(and(
      eq(schema.chatParticipants.chatId, privateThread.id),
      inArray(schema.chatParticipants.userId, [leaverBot.id, removedBot.id]),
    ))).toEqual([])
    expect(await hasChatAccess(privateThread.id, leaverBot.id)).toBe(false)
    expect(await hasChatAccess(privateThread.id, removedBot.id)).toBe(false)
  })

  test("deleting a Space requires a current owner, not the original creator", async () => {
    const creator = await testUtils.createUser("rules-delete-creator@example.com")
    const owner = await testUtils.createUser("rules-delete-owner@example.com")
    const admin = await testUtils.createUser("rules-delete-admin@example.com")
    const space = await testUtils.createSpace("Delete Authority")
    if (!space) throw new Error("Failed to create Space")
    await db.update(schema.spaces).set({ creatorId: creator.id }).where(eq(schema.spaces.id, space.id))
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: creator.id, role: "owner" },
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: admin.id, role: "admin" },
    ])

    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      await leaveSpace({ spaceId: space.id }, legacyContext(creator.id))

      for (const userId of [creator.id, admin.id]) {
        const attempt = deleteSpace({ spaceId: space.id }, legacyContext(userId))
        await expect(attempt).rejects.toBeInstanceOf(InlineError)
        await expect(attempt).rejects.toMatchObject({ type: "SPACE_CREATOR_REQUIRED" })
      }
      const [stillLive] = await db.select().from(schema.spaces).where(eq(schema.spaces.id, space.id))
      expect(stillLive?.deleted).toBeNull()

      await deleteSpace({ spaceId: space.id }, legacyContext(owner.id))
    } finally {
      push.mockRestore()
    }
    const [deleted] = await db.select().from(schema.spaces).where(eq(schema.spaces.id, space.id))
    expect(deleted?.deleted).toBeInstanceOf(Date)
  })
})
