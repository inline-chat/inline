import { describe, test, expect, spyOn } from "bun:test"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import {
  chatParticipantGroups,
  chatParticipants,
  chats,
  dialogs,
  members,
  messages,
  spaces,
  userGroupMembers,
  userGroups,
  users as usersTable,
} from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { ChatModel } from "@in/server/db/models/chats"
import { SpaceModel } from "@in/server/db/models/spaces"
import { updates, UpdateBucket } from "@in/server/db/schema/updates"

const floorWireDate = (date: Date): bigint => BigInt(Math.floor(date.getTime() / 1000))

const insertDurableUpdate = async (params: {
  bucket: UpdateBucket
  entityId: number
  seq: number
  date: Date
}) => {
  await db.insert(updates).values({
    bucket: params.bucket,
    entityId: params.entityId,
    seq: params.seq,
    payload: Buffer.from([0]),
    date: params.date,
  })
}

describe("getUpdatesState", () => {
  setupTestLifecycle()

  test("rejects discovery when a hint batch cannot be queued", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Hint send failure", ["hint-send-failure@example.com"])
    const user = users[0]
    const chat = await testUtils.createChat(space.id, "Changed chat", "thread", true)
    if (!user || !chat) throw new Error("Fixture creation failed")
    await db.update(chats).set({ lastUpdateDate: new Date(), updateSeq: 1 }).where(eq(chats.id, chat.id))
    const failure = new Error("hint queue unavailable")
    const push = spyOn(RealtimeUpdates, "pushToUser").mockRejectedValue(failure)
    try {
      await expect(getUpdatesState({ date: 1n }, testUtils.functionContext({ userId: user.id })))
        .rejects.toBe(failure)
    } finally {
      push.mockRestore()
    }
  })

  test("does not begin a hint batch after an internal repair lifecycle stops", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Stopped repair hints", ["stopped-repair-hints@example.com"])
    const user = users[0]
    const chat = await testUtils.createChat(space.id, "Changed chat", "thread", true)
    if (!user || !chat) throw new Error("Fixture creation failed")
    await db.update(chats).set({ lastUpdateDate: new Date(), updateSeq: 1 }).where(eq(chats.id, chat.id))
    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      const result = await getUpdatesState(
        { date: 1n },
        testUtils.functionContext({ userId: user.id }),
        { shouldEmitHints: () => false },
      )
      expect(result.updatesFound).toBe(true)
      expect(push).not.toHaveBeenCalled()
    } finally {
      push.mockRestore()
    }
  })

  for (const revocation of ["membership", "space deletion"] as const) {
    test(`retained linked-child rows do not expose hints after ${revocation}`, async () => {
      const { users, space } = await testUtils.createSpaceWithMembers("Child hint authority", [
        `child-hint-${revocation.replaceAll(" ", "-")}@example.com`,
      ])
      const user = users[0]
      const parent = await testUtils.createChat(space.id, "Root", "thread", true)
      if (!user || !parent) throw new Error("Fixture creation failed")
      await db.insert(messages).values({ chatId: parent.id, messageId: 1, fromId: user.id })
      const [child] = await db.insert(chats).values({
        type: "thread", spaceId: space.id, parentChatId: parent.id, parentMessageId: 1,
        publicThread: false, updateSeq: 1, lastUpdateDate: new Date(),
      }).returning()
      if (!child) throw new Error("Fixture child missing")
      await db.insert(chatParticipants).values({ chatId: child.id, userId: user.id })
      await db.insert(dialogs).values({ chatId: child.id, userId: user.id, spaceId: space.id })
      if (revocation === "membership") {
        await db.delete(members).where(and(eq(members.spaceId, space.id), eq(members.userId, user.id)))
      } else {
        await db.update(spaces).set({ deleted: new Date() }).where(eq(spaces.id, space.id))
      }
      const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
      try {
        await getUpdatesState({ date: 1n }, testUtils.functionContext({ userId: user.id }))
        const hints = push.mock.calls.flatMap(([, updates]) => updates)
        expect(hints.some((hint) => hint.update.oneofKind === "chatHasNewUpdates" &&
          hint.update.chatHasNewUpdates.chatId === BigInt(child.id))).toBe(false)
        expect(await db.select().from(dialogs).where(eq(dialogs.chatId, child.id))).toHaveLength(1)
        expect(await db.select().from(chatParticipants).where(eq(chatParticipants.chatId, child.id))).toHaveLength(1)
      } finally {
        push.mockRestore()
      }
    })
  }

  test("retained root participant does not authorize a hint after membership changes post-catalog", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Root hint authority", [
      "root-hint-authority@example.com",
    ])
    const user = users[0]
    const chat = await testUtils.createChat(space.id, "Private Root", "thread", false)
    if (!user || !chat) throw new Error("Fixture creation failed")
    await db.insert(chatParticipants).values({ chatId: chat.id, userId: user.id })
    await db.update(chats).set({ lastUpdateDate: new Date(), updateSeq: 1 }).where(eq(chats.id, chat.id))

    const originalGetChats = ChatModel.getUserChats.bind(ChatModel)
    const getChats = spyOn(ChatModel, "getUserChats").mockImplementationOnce(async (query) => {
      const result = await originalGetChats(query)
      await db.delete(members).where(and(eq(members.spaceId, space.id), eq(members.userId, user.id)))
      return result
    })
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      await getUpdatesState(
        { date: floorWireDate(new Date(Date.now() - 60_000)) },
        testUtils.functionContext({ userId: user.id }),
      )
      const hints = push.mock.calls.flatMap(([, updates]) => updates)
      expect(hints.some((hint) => hint.update.oneofKind === "chatHasNewUpdates" &&
        hint.update.chatHasNewUpdates.chatId === BigInt(chat.id))).toBe(false)
      expect(await db.select().from(chatParticipants).where(eq(chatParticipants.chatId, chat.id))).toHaveLength(1)
    } finally {
      getChats.mockRestore()
      push.mockRestore()
    }
  })

  test("retained root group does not authorize a hint after Space deletion post-catalog", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Root group authority", [
      "root-group-authority@example.com",
    ])
    const user = users[0]
    const chat = await testUtils.createChat(space.id, "Group Root", "thread", false)
    if (!user || !chat) throw new Error("Fixture creation failed")
    const [group] = await db.insert(userGroups)
      .values({ spaceId: space.id, name: "Root Readers", createdBy: user.id }).returning()
    if (!group) throw new Error("Group creation failed")
    await db.insert(userGroupMembers).values({ groupId: group.id, userId: user.id })
    await db.insert(chatParticipantGroups).values({ chatId: chat.id, groupId: group.id })
    await db.update(chats).set({ lastUpdateDate: new Date(), updateSeq: 1 }).where(eq(chats.id, chat.id))

    const originalGetChats = ChatModel.getUserChats.bind(ChatModel)
    const getChats = spyOn(ChatModel, "getUserChats").mockImplementationOnce(async (query) => {
      const result = await originalGetChats(query)
      await db.update(spaces).set({ deleted: new Date() }).where(eq(spaces.id, space.id))
      return result
    })
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      await getUpdatesState(
        { date: floorWireDate(new Date(Date.now() - 60_000)) },
        testUtils.functionContext({ userId: user.id }),
      )
      const hints = push.mock.calls.flatMap(([, updates]) => updates)
      expect(hints.some((hint) => hint.update.oneofKind === "chatHasNewUpdates" &&
        hint.update.chatHasNewUpdates.chatId === BigInt(chat.id))).toBe(false)
      expect(await db.select().from(chatParticipantGroups)
        .where(eq(chatParticipantGroups.chatId, chat.id))).toHaveLength(1)
    } finally {
      getChats.mockRestore()
      push.mockRestore()
    }
  })

  test("retained public root does not authorize a hint after Space deletion post-catalog", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Public root authority", [
      "public-root-authority@example.com",
    ])
    const user = users[0]
    const chat = await testUtils.createChat(space.id, "Public Root", "thread", true)
    if (!user || !chat) throw new Error("Fixture creation failed")
    await db.update(chats).set({ lastUpdateDate: new Date(), updateSeq: 1 }).where(eq(chats.id, chat.id))

    const originalGetChats = ChatModel.getUserChats.bind(ChatModel)
    const getChats = spyOn(ChatModel, "getUserChats").mockImplementationOnce(async (query) => {
      const result = await originalGetChats(query)
      await db.update(spaces).set({ deleted: new Date() }).where(eq(spaces.id, space.id))
      return result
    })
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      await getUpdatesState(
        { date: floorWireDate(new Date(Date.now() - 60_000)) },
        testUtils.functionContext({ userId: user.id }),
      )
      const hints = push.mock.calls.flatMap(([, updates]) => updates)
      expect(hints.some((hint) => hint.update.oneofKind === "chatHasNewUpdates" &&
        hint.update.chatHasNewUpdates.chatId === BigInt(chat.id))).toBe(false)
    } finally {
      getChats.mockRestore()
      push.mockRestore()
    }
  })

  test("returns a fresh current checkpoint without discovering old bucket work", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Zero", [
      "updates-state-zero@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Zero Date Updated Chat", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    const chatUpdateDate = new Date(Date.now() + 30 * 1000)
    await db
      .update(chats)
      .set({
        lastUpdateDate: chatUpdateDate,
        updateSeq: 9,
      })
      .where(eq(chats.id, chat.id))
      .execute()
    await db
      .update(spaces)
      .set({ lastUpdateDate: chatUpdateDate, updateSeq: 5 })
      .where(eq(spaces.id, space.id))
      .execute()
    await db.update(usersTable).set({ updateSeq: 17 }).where(eq(usersTable.id, user.id)).execute()

    const before = floorWireDate(new Date())
    const result = await getUpdatesState({}, testUtils.functionContext({ userId: user.id }))
    const after = floorWireDate(new Date())

    expect(result.date).toBeGreaterThanOrEqual(before)
    expect(result.date).toBeLessThanOrEqual(after)
    expect(result.updatesFound).toBe(false)
    expect(result.seq).toBe(17)
  })

  test("accepts the released zero cursor sentinel as a fresh checkpoint", async () => {
    const user = await testUtils.createUser("updates-state-legacy-zero@example.com")

    const result = await getUpdatesState(
      { date: 0n },
      testUtils.functionContext({ userId: user.id }),
    )

    expect(result.date).toBeGreaterThan(0n)
    expect(result.updatesFound).toBe(false)
    expect(result.seq).toBe(0)
  })

  test("fresh checkpoint reconciles a stale user counter with persisted updates", async () => {
    const user = await testUtils.createUser("updates-state-stale-user-seq@example.com")

    await UserBucketUpdates.enqueue({
      userId: user.id,
      update: {
        oneofKind: "userDialogArchived",
        userDialogArchived: {
          peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
          archived: true,
        },
      },
    })
    await db.update(usersTable).set({ updateSeq: null }).where(eq(usersTable.id, user.id)).execute()

    const lazyResult = await getUpdatesState({}, testUtils.functionContext({ userId: user.id }))
    expect(lazyResult.seq).toBe(1)

    await UserBucketUpdates.enqueue({
      userId: user.id,
      update: {
        oneofKind: "userDialogArchived",
        userDialogArchived: {
          peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
          archived: false,
        },
      },
    })
    await db.update(usersTable).set({ updateSeq: 1 }).where(eq(usersTable.id, user.id)).execute()

    const staleResult = await getUpdatesState({}, testUtils.functionContext({ userId: user.id }))
    expect(staleResult.seq).toBe(2)
  })

  test("advances date when there are no updates", async () => {
    const user = await testUtils.createUser("updates-state-empty@example.com")

    const inputDate = floorWireDate(new Date())
    const result = await getUpdatesState(
      { date: inputDate },
      testUtils.functionContext({ userId: user.id }),
    )

    // With an inclusive scan, advancing to the scan-start second is safe and
    // ensures work committed during the scan can be found on the next call.
    expect(result.date >= inputDate).toBe(true)
    expect(result.updatesFound).toBe(false)
  })

  test("returns an explicit regressed checkpoint for a future input date", async () => {
    const user = await testUtils.createUser("updates-state-ahead@example.com")
    const before = floorWireDate(new Date())

    const getChats = spyOn(ChatModel, "getUserChats").mockResolvedValue({ chats: [] } as never)
    const getSpaces = spyOn(SpaceModel, "getSpacesAfterUpdateDate").mockResolvedValue([])

    try {
      const inputDate = before + 60n * 60n
      const result = await getUpdatesState(
        { date: inputDate },
        testUtils.functionContext({ userId: user.id }),
      )
      expect(result).toMatchObject({ updatesFound: false, seq: 0 })
      expect(result.date).toBeGreaterThanOrEqual(before)
      expect(result.date).toBeLessThan(inputDate)
      expect(getChats).not.toHaveBeenCalled()
      expect(getSpaces).not.toHaveBeenCalled()
    } finally {
      getSpaces.mockRestore()
      getChats.mockRestore()
    }
  })

  test("returns the database barrier watermark instead of a resource timestamp", async () => {
    const user = await testUtils.createUser("updates-state-fractional@example.com")
    const inputDate = floorWireDate(new Date(Date.now() - 60_000))
    const changedDate = new Date(Date.now() + 10_000)

    const getChats = spyOn(ChatModel, "getUserChats").mockResolvedValue({ chats: [] } as never)
    const getSpaces = spyOn(SpaceModel, "getSpacesAfterUpdateDate").mockResolvedValue([
      { id: 1, lastUpdateDate: changedDate, updateSeq: 9 },
    ] as never)
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})

    try {
      const result = await getUpdatesState(
        { date: inputDate },
        testUtils.functionContext({ userId: user.id }),
      )

      // Discovery uses its fenced DB checkpoint, not a target timestamp that
      // could move the account cursor beyond unrelated concurrent work.
      expect(result.date).toBeGreaterThanOrEqual(inputDate)
      expect(result.date).toBeLessThan(floorWireDate(changedDate))
      expect(result.updatesFound).toBe(true)
      expect(push).toHaveBeenCalledTimes(1)
    } finally {
      push.mockRestore()
      getSpaces.mockRestore()
      getChats.mockRestore()
    }
  })

  test("keeps a chat change committed between scans discoverable", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Race", [
      "updates-state-race@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Chat Updated Between Scans", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    const scanStart = new Date()
    const scanStartDate = floorWireDate(scanStart)
    const oldDate = new Date(scanStart.getTime() - 120_000)
    const chatUpdateDate = new Date(scanStart.getTime() + 5_000)
    const spaceUpdateDate = new Date(scanStart.getTime() + 10_000)
    await db
      .update(chats)
      .set({ lastUpdateDate: oldDate, updateSeq: 1 })
      .where(eq(chats.id, chat.id))
      .execute()
    await db
      .update(spaces)
      .set({ lastUpdateDate: oldDate, updateSeq: 1 })
      .where(eq(spaces.id, space.id))
      .execute()

    let releaseChatScan: (() => void) | undefined
    const chatScanReleased = new Promise<void>((resolve) => {
      releaseChatScan = resolve
    })
    let chatScanComplete: (() => void) | undefined
    const chatScanFinished = new Promise<void>((resolve) => {
      chatScanComplete = resolve
    })
    const originalGetChats = ChatModel.getUserChats.bind(ChatModel)
    let chatScanCount = 0
    const getChats = spyOn(ChatModel, "getUserChats").mockImplementation(async (query) => {
      const result = await originalGetChats(query)
      if (chatScanCount++ === 0) {
        chatScanComplete?.()
        await chatScanReleased
        // The first scan completed before the new chat timestamp was written.
        return { chats: [] } as never
      }
      return result
    })
    let spaceScanCount = 0
    const originalGetSpaces = SpaceModel.getSpacesAfterUpdateDate.bind(SpaceModel)
    const getSpaces = spyOn(SpaceModel, "getSpacesAfterUpdateDate").mockImplementation(async (query) => {
      if (spaceScanCount++ === 0) {
        return [{ ...space, lastUpdateDate: spaceUpdateDate, updateSeq: 13 }]
      }
      return originalGetSpaces(query)
    })
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    let restored = false
    try {
      const firstResultPromise = getUpdatesState(
        { date: scanStartDate - 60n },
        testUtils.functionContext({ userId: user.id }),
      )
      await chatScanFinished

      // This write happens after the chat scan but before the space scan. A
      // rounded space timestamp must not advance the returned cursor past it.
      await db
        .update(chats)
        .set({ lastUpdateDate: chatUpdateDate, updateSeq: 19 })
        .where(eq(chats.id, chat.id))
        .execute()
      await db
        .update(spaces)
        .set({ lastUpdateDate: spaceUpdateDate, updateSeq: 13 })
        .where(eq(spaces.id, space.id))
        .execute()
      releaseChatScan?.()

      const firstResult = await firstResultPromise
      expect(firstResult.date).toBeGreaterThanOrEqual(scanStartDate)
      expect(firstResult.date).toBeLessThan(floorWireDate(chatUpdateDate))
      expect(firstResult.updatesFound).toBe(true)
      const firstHints = push.mock.calls.flatMap(([, updates]) => updates)
      expect(firstHints.some((update) =>
        update.update.oneofKind === "spaceHasNewUpdates" &&
        update.update.spaceHasNewUpdates.spaceId === BigInt(space.id),
      )).toBe(true)

      getSpaces.mockRestore()
      getChats.mockRestore()
      restored = true
      push.mockClear()

      // Inclusive re-scanning may duplicate work, but the chat update cannot
      // be missed behind the space timestamp observed by the first call.
      const secondResult = await getUpdatesState(
        { date: firstResult.date },
        testUtils.functionContext({ userId: user.id }),
      )
      expect(secondResult.date).toBeGreaterThanOrEqual(firstResult.date)
      expect(secondResult.updatesFound).toBe(true)
      const hints = push.mock.calls.flatMap(([, updates]) => updates)
      expect(hints.some((update) =>
        update.update.oneofKind === "spaceHasNewUpdates" &&
        update.update.spaceHasNewUpdates.spaceId === BigInt(space.id),
      )).toBe(true)
      expect(hints.some((update) =>
        update.update.oneofKind === "chatHasNewUpdates" &&
        update.update.chatHasNewUpdates.chatId === BigInt(chat.id),
      )).toBe(true)
    } finally {
      releaseChatScan?.()
      if (!restored) {
        getSpaces.mockRestore()
        getChats.mockRestore()
      }
      push.mockRestore()
    }
  })

  test("returns latest chat lastUpdateDate when chats changed since input", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Chat", ["u1@example.com"])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Chat Updated", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    const inputDate = floorWireDate(new Date(Date.now() - 60 * 1000))
    const chatUpdateDate = new Date(Date.now() - 30 * 1000)
    await db
      .update(chats)
      .set({
        lastUpdateDate: chatUpdateDate,
        updateSeq: 7,
      })
      .where(eq(chats.id, chat.id))
      .execute()

    const result = await getUpdatesState({ date: inputDate }, testUtils.functionContext({ userId: user.id }))
    expect(result.date).toBeGreaterThanOrEqual(floorWireDate(chatUpdateDate))
    expect(result.date).toBeLessThanOrEqual(floorWireDate(new Date()))
    expect(result.updatesFound).toBe(true)
  })

  test("returns latest space lastUpdateDate when spaces changed since input", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Space", ["u2@example.com"])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const inputDate = floorWireDate(new Date(Date.now() - 60 * 1000))
    const spaceUpdateDate = new Date(Date.now() - 30 * 1000)
    await db
      .update(spaces)
      .set({
        lastUpdateDate: spaceUpdateDate,
        updateSeq: 3,
      })
      .where(eq(spaces.id, space.id))
      .execute()

    const result = await getUpdatesState({ date: inputDate }, testUtils.functionContext({ userId: user.id }))
    expect(result.date).toBeGreaterThanOrEqual(floorWireDate(spaceUpdateDate))
    expect(result.date).toBeLessThanOrEqual(floorWireDate(new Date()))
    expect(result.updatesFound).toBe(true)
  })

  test("emits an authoritative space hint when a changed space counter is absent", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Space Hint", [
      "space-hint@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const inputDate = floorWireDate(new Date(Date.now() - 60 * 1000))
    const spaceUpdateDate = new Date(Date.now() - 30 * 1000)
    await db
      .update(spaces)
      .set({
        lastUpdateDate: spaceUpdateDate,
        updateSeq: null,
      })
      .where(eq(spaces.id, space.id))
      .execute()

    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      const result = await getUpdatesState(
        { date: inputDate },
        testUtils.functionContext({ userId: user.id }),
      )

      expect(result.updatesFound).toBe(true)
      expect(push).toHaveBeenCalledWith(user.id, [
        {
          update: {
            oneofKind: "spaceHasNewUpdates",
            spaceHasNewUpdates: {
              spaceId: BigInt(space.id),
              updateSeq: 0,
            },
          },
        },
      ])
    } finally {
      push.mockRestore()
    }
  })

  test("reconciles stale non-null target counters from the durable journal", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Durable Seq", [
      "updates-state-durable-seq@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Durable Seq Chat", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    const scanStart = new Date()
    const scanStartDate = floorWireDate(scanStart)
    const changedDate = new Date(scanStart.getTime() - 30_000)
    await db
      .update(chats)
      .set({ lastUpdateDate: changedDate, updateSeq: 2 })
      .where(eq(chats.id, chat.id))
      .execute()
    await db
      .update(spaces)
      .set({ lastUpdateDate: changedDate, updateSeq: 4 })
      .where(eq(spaces.id, space.id))
      .execute()
    await insertDurableUpdate({ bucket: UpdateBucket.Chat, entityId: chat.id, seq: 7, date: changedDate })
    await insertDurableUpdate({ bucket: UpdateBucket.Space, entityId: space.id, seq: 9, date: changedDate })

    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      const result = await getUpdatesState(
        { date: scanStartDate - 60n },
        testUtils.functionContext({ userId: user.id }),
      )

      expect(result.date).toBeGreaterThanOrEqual(scanStartDate)
      const hints = push.mock.calls.flatMap(([, updates]) => updates)
      const chatHint = hints.find((update) => update.update.oneofKind === "chatHasNewUpdates")
      const spaceHint = hints.find((update) => update.update.oneofKind === "spaceHasNewUpdates")
      if (chatHint?.update.oneofKind === "chatHasNewUpdates") {
        expect(chatHint.update.chatHasNewUpdates.updateSeq).toBe(7)
      } else {
        throw new Error("Chat discovery hint was not emitted")
      }
      if (spaceHint?.update.oneofKind === "spaceHasNewUpdates") {
        expect(spaceHint.update.spaceHasNewUpdates.updateSeq).toBe(9)
      } else {
        throw new Error("Space discovery hint was not emitted")
      }
    } finally {
      push.mockRestore()
    }
  })

  test("reconciles a delayed old-timestamp commit for an emitted target", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Delayed Commit", [
      "updates-state-delayed-commit@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Delayed Commit Chat", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    const scanStart = new Date()
    const scanStartDate = floorWireDate(scanStart)
    const oldUpdateDate = new Date(scanStart.getTime() - 30_000)
    await db
      .update(chats)
      .set({ lastUpdateDate: oldUpdateDate, updateSeq: 2 })
      .where(eq(chats.id, chat.id))
      .execute()
    await db
      .update(spaces)
      .set({ lastUpdateDate: oldUpdateDate, updateSeq: 2 })
      .where(eq(spaces.id, space.id))
      .execute()
    await insertDurableUpdate({ bucket: UpdateBucket.Chat, entityId: chat.id, seq: 2, date: oldUpdateDate })

    let releaseChatScan: (() => void) | undefined
    const chatScanReleased = new Promise<void>((resolve) => {
      releaseChatScan = resolve
    })
    let chatScanComplete: (() => void) | undefined
    const chatScanFinished = new Promise<void>((resolve) => {
      chatScanComplete = resolve
    })
    const originalGetChats = ChatModel.getUserChats.bind(ChatModel)
    const getChats = spyOn(ChatModel, "getUserChats").mockImplementation(async (query) => {
      const result = await originalGetChats(query)
      chatScanComplete?.()
      await chatScanReleased
      return result
    })
    const originalGetSpaces = SpaceModel.getSpacesAfterUpdateDate.bind(SpaceModel)
    const getSpaces = spyOn(SpaceModel, "getSpacesAfterUpdateDate").mockImplementation(async (query) =>
      originalGetSpaces(query)
    )
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    let restored = false
    try {
      const resultPromise = getUpdatesState(
        { date: scanStartDate - 60n },
        testUtils.functionContext({ userId: user.id }),
      )
      await chatScanFinished

      // This journal row commits after the chat scan, but carries an old
      // timestamp. A time gap cannot make this safe; the emitted target's
      // durable maximum sequence is the smallest compatible repair.
      await insertDurableUpdate({ bucket: UpdateBucket.Chat, entityId: chat.id, seq: 3, date: oldUpdateDate })
      releaseChatScan?.()

      const result = await resultPromise
      expect(result.date).toBeGreaterThanOrEqual(scanStartDate)
      const hints = push.mock.calls.flatMap(([, updates]) => updates)
      const chatHint = hints.find((update) => update.update.oneofKind === "chatHasNewUpdates")
      if (chatHint?.update.oneofKind === "chatHasNewUpdates") {
        expect(chatHint.update.chatHasNewUpdates.updateSeq).toBe(3)
      } else {
        throw new Error("Chat discovery hint was not emitted")
      }
      expect(getSpaces).toHaveBeenCalledTimes(1)
    } finally {
      releaseChatScan?.()
      if (!restored) {
        getSpaces.mockRestore()
        getChats.mockRestore()
      }
      push.mockRestore()
    }
  })

  test("publishes large discovery results as bounded ordered hint batches", async () => {
    const user = await testUtils.createUser("updates-state-bounded-hints@example.com")
    const inputDate = floorWireDate(new Date(Date.now() - 60 * 1000))
    const updateDate = new Date(Date.now() - 30 * 1000)
    const changedSpaces = Array.from({ length: 1_025 }, (_, index) => ({
      id: index + 1,
      lastUpdateDate: updateDate,
      updateSeq: index + 10,
    }))
    const getChats = spyOn(ChatModel, "getUserChats").mockResolvedValue({ chats: [] } as never)
    const getSpaces = spyOn(SpaceModel, "getSpacesAfterUpdateDate").mockResolvedValue(changedSpaces as never)
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      const result = await getUpdatesState(
        { date: inputDate },
        testUtils.functionContext({ userId: user.id }),
      )

      expect(result.updatesFound).toBe(true)
      expect(result.date).toBeGreaterThanOrEqual(floorWireDate(updateDate))
      expect(result.date).toBeLessThanOrEqual(floorWireDate(new Date()))
      expect(push).toHaveBeenCalledTimes(3)
      const batches = push.mock.calls.map(([, updates]) => updates)
      expect(batches.map((batch) => batch.length)).toEqual([512, 512, 1])
      expect(batches.flat().map((update) =>
        update.update.oneofKind === "spaceHasNewUpdates"
          ? Number(update.update.spaceHasNewUpdates.spaceId)
          : 0,
      )).toEqual(changedSpaces.map((space) => space.id))
    } finally {
      push.mockRestore()
      getSpaces.mockRestore()
      getChats.mockRestore()
    }
  })

  test("returns max(chat, space) lastUpdateDate when both changed since input", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Max", ["u3@example.com"])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Chat Updated 2", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    const inputDate = floorWireDate(new Date(Date.now() - 60 * 1000))
    const chatUpdateDate = new Date(Date.now() - 50 * 1000)
    const spaceUpdateDate = new Date(Date.now() - 40 * 1000)

    await db
      .update(chats)
      .set({
        lastUpdateDate: chatUpdateDate,
        updateSeq: 11,
      })
      .where(eq(chats.id, chat.id))
      .execute()

    await db
      .update(spaces)
      .set({
        lastUpdateDate: spaceUpdateDate,
        updateSeq: 4,
      })
      .where(eq(spaces.id, space.id))
      .execute()

    const result = await getUpdatesState({ date: inputDate }, testUtils.functionContext({ userId: user.id }))
    expect(result.date).toBeGreaterThanOrEqual(floorWireDate(spaceUpdateDate))
    expect(result.date).toBeLessThanOrEqual(floorWireDate(new Date()))
    expect(result.updatesFound).toBe(true)
  })

  test("skips changed public chats when member no longer has public chat access", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State No Public", [
      "no-public@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Public But Inaccessible", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await db
      .update(members)
      .set({ canAccessPublicChats: false })
      .where(and(eq(members.spaceId, space.id), eq(members.userId, user.id)))
      .execute()

    const inputDate = floorWireDate(new Date(Date.now() - 60 * 1000))
    const chatUpdateDate = new Date(Date.now() - 30 * 1000)
    await db
      .update(chats)
      .set({
        lastUpdateDate: chatUpdateDate,
        updateSeq: 7,
      })
      .where(eq(chats.id, chat.id))
      .execute()

    const result = await getUpdatesState({ date: inputDate }, testUtils.functionContext({ userId: user.id }))
    expect(result.date).toBeGreaterThanOrEqual(inputDate)
    expect(result.date).not.toBe(floorWireDate(chatUpdateDate))
    expect(result.updatesFound).toBe(false)
  })
})
