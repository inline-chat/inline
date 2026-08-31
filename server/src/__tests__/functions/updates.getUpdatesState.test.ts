import { describe, test, expect, spyOn } from "bun:test"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { chats, members, spaces, users as usersTable } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { ChatModel } from "@in/server/db/models/chats"
import { SpaceModel } from "@in/server/db/models/spaces"

describe("getUpdatesState", () => {
  setupTestLifecycle()

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

    const before = encodeDateStrict(new Date())
    const result = await getUpdatesState({}, testUtils.functionContext({ userId: user.id }))
    const after = encodeDateStrict(new Date())

    expect(result.date).toBeGreaterThanOrEqual(before)
    expect(result.date).toBeLessThanOrEqual(after)
    expect(result.updatesFound).toBe(false)
    expect(result.seq).toBe(17)
  })

  test("rejects zero as an explicit discovery date", async () => {
    const user = await testUtils.createUser("updates-state-invalid-zero@example.com")

    await expect(
      getUpdatesState({ date: 0n }, testUtils.functionContext({ userId: user.id })),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
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

    const inputDate = encodeDateStrict(new Date())
    const result = await getUpdatesState(
      { date: inputDate },
      testUtils.functionContext({ userId: user.id }),
    )

    // The function should not regress the cursor. If there are no updates, it should
    // advance it to at least now (or preserve input if it's already ahead).
    expect(result.date >= inputDate).toBe(true)
    expect(result.updatesFound).toBe(false)
  })

  test("preserves input date when it's already ahead (no updates)", async () => {
    const user = await testUtils.createUser("updates-state-ahead@example.com")

    const inputDate = encodeDateStrict(new Date(Date.now() + 60 * 60 * 1000))
    const result = await getUpdatesState({ date: inputDate }, testUtils.functionContext({ userId: user.id }))

    expect(result.date).toBe(inputDate)
    expect(result.updatesFound).toBe(false)
  })

  test("returns latest chat lastUpdateDate when chats changed since input", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Chat", ["u1@example.com"])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Chat Updated", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    const inputDate = encodeDateStrict(new Date(Date.now() - 60 * 1000))
    const chatUpdateDate = new Date(Date.now() + 30 * 1000)
    await db
      .update(chats)
      .set({
        lastUpdateDate: chatUpdateDate,
        updateSeq: 7,
      })
      .where(eq(chats.id, chat.id))
      .execute()

    const result = await getUpdatesState({ date: inputDate }, testUtils.functionContext({ userId: user.id }))
    expect(result.date).toBe(encodeDateStrict(chatUpdateDate))
    expect(result.updatesFound).toBe(true)
  })

  test("returns latest space lastUpdateDate when spaces changed since input", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Space", ["u2@example.com"])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const inputDate = encodeDateStrict(new Date(Date.now() - 60 * 1000))
    const spaceUpdateDate = new Date(Date.now() + 45 * 1000)
    await db
      .update(spaces)
      .set({
        lastUpdateDate: spaceUpdateDate,
        updateSeq: 3,
      })
      .where(eq(spaces.id, space.id))
      .execute()

    const result = await getUpdatesState({ date: inputDate }, testUtils.functionContext({ userId: user.id }))
    expect(result.date).toBe(encodeDateStrict(spaceUpdateDate))
    expect(result.updatesFound).toBe(true)
  })

  test("emits an authoritative space hint when a changed space counter is absent", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Updates State Space Hint", [
      "space-hint@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const inputDate = encodeDateStrict(new Date(Date.now() - 60 * 1000))
    const spaceUpdateDate = new Date(Date.now() + 45 * 1000)
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

  test("publishes large discovery results as bounded ordered hint batches", async () => {
    const user = await testUtils.createUser("updates-state-bounded-hints@example.com")
    const inputDate = encodeDateStrict(new Date(Date.now() - 60 * 1000))
    const updateDate = new Date(Date.now() + 30 * 1000)
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

      expect(result).toMatchObject({
        date: encodeDateStrict(updateDate),
        updatesFound: true,
      })
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

    const inputDate = encodeDateStrict(new Date(Date.now() - 60 * 1000))
    const chatUpdateDate = new Date(Date.now() + 10 * 1000)
    const spaceUpdateDate = new Date(Date.now() + 20 * 1000)

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
    expect(result.date).toBe(encodeDateStrict(spaceUpdateDate))
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

    const inputDate = encodeDateStrict(new Date(Date.now() - 60 * 1000))
    const chatUpdateDate = new Date(Date.now() + 30 * 1000)
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
    expect(result.date).not.toBe(encodeDateStrict(chatUpdateDate))
    expect(result.updatesFound).toBe(false)
  })
})
