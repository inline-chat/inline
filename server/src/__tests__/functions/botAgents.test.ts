import { beforeEach, describe, expect, test } from "bun:test"
import {
  createBotAgent,
  deleteBotAgent,
  getBotAgent,
  listBotAgents,
  updateBotAgent,
} from "@in/server/functions/bot.agents"
import { createBot } from "@in/server/functions/createBot"
import type { FunctionContext } from "@in/server/functions/_types"
import { defaultTestContext, setupTestLifecycle, testUtils } from "../setup"

describe("bot Agents", () => {
  setupTestLifecycle()

  let creatorContext: FunctionContext
  let otherContext: FunctionContext

  beforeEach(async () => {
    const creator = await testUtils.createUser("agent-creator@example.com")
    const other = await testUtils.createUser("agent-other@example.com")
    creatorContext = { currentSessionId: defaultTestContext.sessionId, currentUserId: creator.id }
    otherContext = { currentSessionId: defaultTestContext.sessionId, currentUserId: other.id }
  })

  test("creator and bot self share the existing management boundary", async () => {
    const createdBot = await createBot(
      { name: "Agent Host", username: "agenthostbot" },
      creatorContext,
    )
    const botUserId = createdBot.bot?.id
    if (!botUserId) throw new Error("Expected bot")

    const created = await createBotAgent(
      { botUserId, name: "  Data Analyst  " },
      creatorContext,
    )
    const agent = created.agent
    if (!agent) throw new Error("Expected Agent")
    expect(agent.name).toBe("Data Analyst")

    const botContext: FunctionContext = {
      currentSessionId: defaultTestContext.sessionId,
      currentUserId: Number(botUserId),
    }
    const fetched = await getBotAgent({ agentId: agent.id }, botContext)
    expect(fetched.bot?.id).toBe(botUserId)
    expect(fetched.agent?.botUserId).toBe(botUserId)

    const listed = await listBotAgents({ botUserId }, botContext)
    expect(listed.agents.map((listedAgent) => listedAgent.id)).toEqual([agent.id])

    const updated = await updateBotAgent({
      agentId: agent.id,
      emoji: "📊",
      description: "Find the signal",
      instructions: "Always show the source.",
    }, creatorContext)
    expect(updated.agent?.emoji).toBe("📊")
    expect(updated.agent?.instructions).toBe("Always show the source.")

    const cleared = await updateBotAgent({
      agentId: agent.id,
      emoji: "",
      instructions: "",
    }, botContext)
    expect(cleared.agent?.emoji).toBeUndefined()
    expect(cleared.agent?.instructions).toBeUndefined()

    expect(await deleteBotAgent({ agentId: agent.id }, creatorContext)).toEqual({
      agentId: agent.id,
    })
    expect((await listBotAgents({ botUserId }, botContext)).agents).toEqual([])
  })

  test("rejects a user who does not manage the backing bot", async () => {
    const createdBot = await createBot(
      { name: "Private Agent Host", username: "privateagenthostbot" },
      creatorContext,
    )
    const botUserId = createdBot.bot?.id
    if (!botUserId) throw new Error("Expected bot")

    await expect(
      createBotAgent({ botUserId, name: "No Access" }, otherContext),
    ).rejects.toThrow()

    const created = await createBotAgent({ botUserId, name: "Protected" }, creatorContext)
    if (!created.agent) throw new Error("Expected Agent")
    await expect(
      updateBotAgent({ agentId: created.agent.id, name: "Stolen" }, otherContext),
    ).rejects.toThrow()
    await expect(deleteBotAgent({ agentId: created.agent.id }, otherContext)).rejects.toThrow()
  })

  test("rejects optional values that exceed their persisted bounds", async () => {
    const createdBot = await createBot(
      { name: "Bounded Agent Host", username: "boundedagenthostbot" },
      creatorContext,
    )
    const botUserId = createdBot.bot?.id
    if (!botUserId) throw new Error("Expected bot")

    await expect(
      createBotAgent({ botUserId, name: "Too Wide", emoji: "x".repeat(65) }, creatorContext),
    ).rejects.toThrow()
    await expect(
      updateBotAgent({ agentId: 9_999_999n, name: "Missing" }, creatorContext),
    ).rejects.toThrow()
  })
})
