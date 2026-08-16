import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { allocateThreadNumber } from "@in/server/modules/threadNumbers"
import { setupTestLifecycle, testUtils } from "../__tests__/setup"

describe("allocateThreadNumber", () => {
  setupTestLifecycle()

  test("allocates monotonic numbers independently for official scope owners", async () => {
    const user = await testUtils.createUser("thread-number-user@example.com")
    const otherUser = await testUtils.createUser("thread-number-other@example.com")
    const space = await testUtils.createSpace("Thread Number Space")
    if (!space) throw new Error("Space not created")

    const firstUserNumber = await db.transaction((tx) =>
      allocateThreadNumber(tx, { type: "user", id: user.id }),
    )
    const secondUserNumber = await db.transaction((tx) =>
      allocateThreadNumber(tx, { type: "user", id: user.id }),
    )
    const otherUserNumber = await db.transaction((tx) =>
      allocateThreadNumber(tx, { type: "user", id: otherUser.id }),
    )
    const spaceNumber = await db.transaction((tx) =>
      allocateThreadNumber(tx, { type: "space", id: space.id }),
    )

    expect([firstUserNumber, secondUserNumber]).toEqual([1, 2])
    expect(otherUserNumber).toBe(1)
    expect(spaceNumber).toBe(1)
  })

  test("serializes concurrent claims on the same scope owner", async () => {
    const user = await testUtils.createUser("thread-number-concurrent@example.com")

    const claimed = await Promise.all(
      Array.from({ length: 4 }, () =>
        db.transaction((tx) => allocateThreadNumber(tx, { type: "user", id: user.id })),
      ),
    )

    expect(claimed.sort((left, right) => left - right)).toEqual([1, 2, 3, 4])
  })
})
