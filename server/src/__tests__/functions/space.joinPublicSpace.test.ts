import { describe, expect, spyOn, test } from "bun:test"
import { db } from "@in/server/db"
import { chats, dialogs, members, spaces, updates, UpdateBucket } from "@in/server/db/schema"
import { UpdatesModel } from "@in/server/db/models/updates"
import { joinPublicSpace } from "@in/server/functions/space.joinPublicSpace"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import { handler as createSpace } from "@in/server/methods/createSpace"
import { Method } from "@inline-chat/protocol/core"
import { normalizeSpaceHandle } from "@in/server/modules/spaces/spaceHandle"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { and, asc, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

const context = (userId: number) => ({ currentUserId: userId, currentSessionId: 1 })

describe("joinPublicSpace", () => {
  setupTestLifecycle()

  test("joins a public space by normalized handle and persists privacy-safe updates", async () => {
    const user = await testUtils.createUser("public-join@example.com")
    const [space] = await db
      .insert(spaces)
      .values({ name: "Town Hall", handle: "TownHall", isPublic: true, canPublicJoin: true })
      .returning()
    if (!space) throw new Error("Failed to create public space")
    const [primaryChat] = await db
      .insert(chats)
      .values({
        spaceId: space.id,
        type: "thread",
        title: space.name,
        publicThread: true,
        threadNumber: 1,
      })
      .returning()
    if (!primaryChat) throw new Error("Failed to create primary chat")
    const [childChat] = await db
      .insert(chats)
      .values({
        spaceId: space.id,
        type: "thread",
        title: "Announcements",
        publicThread: true,
        parentChatId: primaryChat.id,
        threadNumber: 2,
      })
      .returning()
    if (!childChat) throw new Error("Failed to create descendant chat")

    const result = await joinPublicSpace({ handle: "  @TOWNHALL  " }, context(user.id))

    expect(result.alreadyMember).toBe(false)
    if (!result.space || !result.member) throw new Error("Expected joined space and member")
    expect(result.space.id).toBe(BigInt(space.id))
    expect(result.space.handle).toBe("TownHall")
    expect(result.space.isPublic).toBe(true)
    expect(result.member.userId).toBe(BigInt(user.id))

    const savedMembers = await db
      .select()
      .from(members)
      .where(and(eq(members.spaceId, space.id), eq(members.userId, user.id)))
    expect(savedMembers).toHaveLength(1)
    expect(savedMembers[0]?.role).toBe("member")
    expect(savedMembers[0]?.canAccessPublicChats).toBe(true)

    const [primaryDialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, primaryChat.id), eq(dialogs.userId, user.id)))
      .limit(1)
    expect(primaryDialog?.open).toBe(true)
    expect(primaryDialog?.order).toBeString()

    const userUpdates = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
    expect(userUpdates).toHaveLength(3)
    const userPayload = UpdatesModel.decrypt(userUpdates[0]!).payload.update
    expect(userPayload.oneofKind).toBe("userJoinSpace")
    if (userPayload.oneofKind !== "userJoinSpace") throw new Error("Expected userJoinSpace")
    if (!userPayload.userJoinSpace.space) throw new Error("Expected joined space update")
    expect(userPayload.userJoinSpace.space.handle).toBe("TownHall")
    const accessChatIds = userUpdates
      .map((row) => UpdatesModel.decrypt(row).payload.update)
      .filter((update) => update.oneofKind === "userAddedToChat")
      .map((update) => update.userAddedToChat.chatId)
    expect(accessChatIds).toEqual([BigInt(primaryChat.id)])
    expect(accessChatIds).not.toContain(BigInt(childChat.id))
    expect(UpdatesModel.decrypt(userUpdates[2]!).payload.update.oneofKind).toBe("userChatOpen")

    const spaceUpdates = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Space), eq(updates.entityId, space.id)))
    expect(spaceUpdates).toHaveLength(1)
    const spacePayload = UpdatesModel.decrypt(spaceUpdates[0]!).payload.update
    expect(spacePayload.oneofKind).toBe("spaceMemberAdd")
    if (spacePayload.oneofKind !== "spaceMemberAdd") throw new Error("Expected spaceMemberAdd")
    if (!spacePayload.spaceMemberAdd.user) throw new Error("Expected added user update")
    expect(spacePayload.spaceMemberAdd.user.min).toBe(true)
    expect(spacePayload.spaceMemberAdd.user.email).toBeUndefined()
    expect(spacePayload.spaceMemberAdd.user.phoneNumber).toBeUndefined()
  })

  test("is idempotent for existing membership without emitting duplicate updates", async () => {
    const user = await testUtils.createUser("public-idempotent@example.com")
    const [space] = await db
      .insert(spaces)
      .values({ name: "Community", handle: "community", isPublic: true, canPublicJoin: true })
      .returning()
    if (!space) throw new Error("Failed to create public space")
    const [primaryChat] = await db
      .insert(chats)
      .values({
        spaceId: space.id,
        type: "thread",
        title: space.name,
        publicThread: true,
        threadNumber: 1,
      })
      .returning()
    if (!primaryChat) throw new Error("Failed to create primary chat")

    const first = await joinPublicSpace({ handle: "community" }, context(user.id))
    const second = await joinPublicSpace({ handle: "COMMUNITY" }, context(user.id))

    expect(first.alreadyMember).toBe(false)
    expect(second.alreadyMember).toBe(true)
    if (!first.member || !second.member) throw new Error("Expected existing membership")
    expect(second.member.id).toBe(first.member.id)
    expect(
      await db
        .select()
        .from(members)
        .where(and(eq(members.spaceId, space.id), eq(members.userId, user.id))),
    ).toHaveLength(1)
    expect(
      await db
        .select()
        .from(dialogs)
        .where(and(eq(dialogs.chatId, primaryChat.id), eq(dialogs.userId, user.id))),
    ).toHaveLength(1)
    expect(await db.select().from(updates)).toHaveLength(4)
  })

  test("repairs an existing member's closed primary dialog once and fans it out to every session", async () => {
    const user = await testUtils.createUser("public-existing-dialog@example.com")
    const [space] = await db
      .insert(spaces)
      .values({ name: "Existing Community", handle: "existingcommunity", isPublic: true, canPublicJoin: true })
      .returning()
    if (!space) throw new Error("Failed to create public space")
    const [primaryChat] = await db
      .insert(chats)
      .values({
        spaceId: space.id,
        type: "thread",
        title: space.name,
        publicThread: true,
        threadNumber: 1,
      })
      .returning()
    if (!primaryChat) throw new Error("Failed to create primary chat")
    await db.insert(members).values({
      spaceId: space.id,
      userId: user.id,
      role: "member",
      canAccessPublicChats: true,
    })
    await db.insert(dialogs).values({
      chatId: primaryChat.id,
      userId: user.id,
      spaceId: space.id,
      open: false,
    })

    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      const first = await joinPublicSpace({ handle: "existingcommunity" }, context(user.id))
      const second = await joinPublicSpace({ handle: "existingcommunity" }, context(user.id))
      expect(first.alreadyMember).toBe(true)
      expect(second.alreadyMember).toBe(true)
      expect(push).toHaveBeenCalledTimes(1)
      const [recipient, liveUpdates, options] = push.mock.calls[0]!
      expect(recipient).toBe(user.id)
      expect(liveUpdates.map((update) => update.update.oneofKind)).toEqual(["chatOpen"])
      expect(options).toBeUndefined()
    } finally {
      push.mockRestore()
    }

    const storedUserUpdates = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(asc(updates.seq))
    expect(storedUserUpdates).toHaveLength(1)
    const payload = UpdatesModel.decrypt(storedUserUpdates[0]!).payload.update
    expect(payload.oneofKind).toBe("userChatOpen")
    if (payload.oneofKind !== "userChatOpen") throw new Error("Expected userChatOpen")
    expect(payload.userChatOpen.chat?.permissions?.canUpdateInfo).toBe(true)
    expect(payload.userChatOpen.chat?.acknowledgements?.cursors).toEqual([])
    expect(payload.userChatOpen.dialog?.unreadCount).toBe(0)

  })

  test("rolls back membership, dialog, and both buckets when chat-open persistence fails", async () => {
    const user = await testUtils.createUser("public-join-rollback@example.com")
    const [space] = await db
      .insert(spaces)
      .values({ name: "Rollback Community", handle: "rollbackcommunity", isPublic: true, canPublicJoin: true })
      .returning()
    if (!space) throw new Error("Failed to create public space")
    const [primaryChat] = await db
      .insert(chats)
      .values({
        spaceId: space.id,
        type: "thread",
        title: space.name,
        publicThread: true,
        threadNumber: 1,
      })
      .returning()
    if (!primaryChat) throw new Error("Failed to create primary chat")

    const originalEnqueue = UserBucketUpdates.enqueue
    let enqueueCount = 0
    const enqueue = spyOn(UserBucketUpdates, "enqueue").mockImplementation(async (input, options) => {
      enqueueCount += 1
      if (enqueueCount === 2) {
        throw new Error("injected chat-open persistence failure")
      }
      return originalEnqueue(input, options)
    })
    try {
      await expect(joinPublicSpace({ handle: "rollbackcommunity" }, context(user.id))).rejects.toThrow(
        "injected chat-open persistence failure",
      )
    } finally {
      enqueue.mockRestore()
    }

    expect(
      await db
        .select()
        .from(members)
        .where(and(eq(members.spaceId, space.id), eq(members.userId, user.id))),
    ).toHaveLength(0)
    expect(await db.select().from(dialogs).where(eq(dialogs.userId, user.id))).toHaveLength(0)
    expect(await db.select().from(updates)).toHaveLength(0)
    const [storedSpace] = await db.select().from(spaces).where(eq(spaces.id, space.id)).limit(1)
    expect(storedSpace?.updateSeq).toBe(0)
  })

  test("serializes concurrent retries into one membership", async () => {
    const user = await testUtils.createUser("public-concurrent@example.com")
    const [space] = await db
      .insert(spaces)
      .values({ name: "Concurrent", handle: "concurrent", isPublic: true, canPublicJoin: true })
      .returning()
    if (!space) throw new Error("Failed to create public space")

    const results = await Promise.all([
      joinPublicSpace({ handle: "concurrent" }, context(user.id)),
      joinPublicSpace({ handle: "concurrent" }, context(user.id)),
    ])

    expect(results.map((result) => result.alreadyMember).sort()).toEqual([false, true])
    expect(
      await db
        .select()
        .from(members)
        .where(and(eq(members.spaceId, space.id), eq(members.userId, user.id))),
    ).toHaveLength(1)
    expect(await db.select().from(updates)).toHaveLength(2)
  })

  test("does not disclose private, deleted, or missing spaces", async () => {
    const user = await testUtils.createUser("public-reject@example.com")
    await db.insert(spaces).values([
      { name: "Private", handle: "privateplace", isPublic: false },
      { name: "Deleted", handle: "deletedplace", isPublic: true, canPublicJoin: true, deleted: new Date() },
      { name: "Disabled", handle: "disabledplace", isPublic: true },
    ])

    for (const handle of ["privateplace", "deletedplace", "disabledplace", "missingplace"]) {
      await expect(joinPublicSpace({ handle }, context(user.id))).rejects.toMatchObject({
        codeName: "SPACE_ID_INVALID",
      })
    }
    expect(await db.select().from(members)).toHaveLength(0)
    expect(await db.select().from(updates)).toHaveLength(0)
  })

  test("dispatches through the RealtimeV2 RPC method", async () => {
    const user = await testUtils.createUser("public-rpc@example.com")
    await db.insert(spaces).values({
      name: "RPC Community",
      handle: "rpccommunity",
      isPublic: true,
      canPublicJoin: true,
    })

    const result = await handleRpcCall(
      {
        method: Method.JOIN_PUBLIC_SPACE,
        input: { oneofKind: "joinPublicSpace", joinPublicSpace: { handle: "rpccommunity" } },
      },
      {
        userId: user.id,
        sessionId: 1,
        connectionId: "join-public-space-test",
        sendRaw: () => {},
        sendRpcReply: () => {},
      },
    )

    expect(result.oneofKind).toBe("joinPublicSpace")
    if (result.oneofKind !== "joinPublicSpace") throw new Error("Expected joinPublicSpace result")
    expect(result.joinPublicSpace.alreadyMember).toBe(false)
  })

  test("enforces case-insensitive handle uniqueness", async () => {
    await db.insert(spaces).values({ name: "First", handle: "CaseHandle", isPublic: true })
    await expect(
      db.insert(spaces).values({ name: "Second", handle: "casehandle", isPublic: true }).execute(),
    ).rejects.toThrow()
  })

  test("uses user-username normalization and validity limits for space handles", () => {
    expect(normalizeSpaceHandle("  @TownHall ")).toBe("TownHall")
    expect(normalizeSpaceHandle("a")).toBeNull()
    expect(normalizeSpaceHandle("admin")).toBeNull()
    expect(normalizeSpaceHandle("x".repeat(257))).toBeNull()
  })

  test("normalizes assigned handles and reports invalid or taken handles", async () => {
    const user = await testUtils.createUser("space-handle-owner@example.com")
    const handlerContext = { currentUserId: user.id, currentSessionId: 1, ip: undefined }

    const created = await createSpace({ name: "Handle Space", handle: "  @HandleSpace  " }, handlerContext)
    expect(created.space.handle).toBe("HandleSpace")

    await expect(createSpace({ name: "Reserved", handle: "admin" }, handlerContext)).rejects.toMatchObject({
      type: "USERNAME_INVALID",
    })
    await expect(createSpace({ name: "Taken", handle: "handlespace" }, handlerContext)).rejects.toMatchObject({
      type: "USERNAME_TAKEN",
    })
  })
})
