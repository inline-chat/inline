import { describe, test, expect } from "bun:test"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { chats, spaces } from "@in/server/db/schema"
import { eq } from "drizzle-orm"

describe("getUpdatesState", () => {
  setupTestLifecycle()

  test("returns now when input date is 0 (uninitialized)", async () => {
    const user = await testUtils.createUser("updates-state-zero@example.com")

    const before = encodeDateStrict(new Date(Date.now() - 5_000))
    const result = await getUpdatesState({ date: 0n }, testUtils.functionContext({ userId: user.id }))

    expect(result.date >= before).toBe(true)
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
  })

  test("preserves input date when it's already ahead (no updates)", async () => {
    const user = await testUtils.createUser("updates-state-ahead@example.com")

    const inputDate = encodeDateStrict(new Date(Date.now() + 60 * 60 * 1000))
    const result = await getUpdatesState({ date: inputDate }, testUtils.functionContext({ userId: user.id }))

    expect(result.date).toBe(inputDate)
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
  })
})
