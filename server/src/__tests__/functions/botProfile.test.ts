import { beforeEach, describe, expect, test } from "bun:test"
import { setupTestLifecycle, defaultTestContext, testUtils } from "../setup"
import type { FunctionContext } from "../../functions/_types"
import { createBot } from "../../functions/createBot"
import { listBots } from "../../functions/bot.listBots"
import { updateBotProfile } from "../../functions/bot.updateProfile"

describe("bot profile", () => {
  setupTestLifecycle()

  let creator: any
  let otherUser: any
  let creatorContext: FunctionContext
  let otherContext: FunctionContext

  beforeEach(async () => {
    creator = await testUtils.createUser("creator@example.com")
    otherUser = await testUtils.createUser("other@example.com")

    creatorContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: creator.id,
    }

    otherContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: otherUser.id,
    }
  })

  test("updateBotProfile updates bot name for creator", async () => {
    const created = await createBot({ name: "Old Name", username: "oldnamebot" }, creatorContext)

    const updated = await updateBotProfile(
      { botUserId: created.bot?.id ?? 0n, name: "New Bot Name" },
      creatorContext,
    )

    expect(updated.bot).toBeDefined()
    expect(updated.bot?.firstName).toBe("New Bot Name")

    const listed = await listBots({}, creatorContext)
    expect(listed.bots.some((b) => b.id === (created.bot?.id ?? 0n) && b.firstName === "New Bot Name")).toBe(true)
  })

  test("updateBotProfile rejects non-creator", async () => {
    const created = await createBot({ name: "Private Bot", username: "privateprofilebot" }, creatorContext)

    await expect(
      updateBotProfile({ botUserId: created.bot?.id ?? 0n, name: "Nope" }, otherContext),
    ).rejects.toThrow()
  })
})

