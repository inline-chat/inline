import { beforeEach, describe, expect, test } from "bun:test"
import { createBotAgent, getBotAgent, listBotAgents } from "@in/server/functions/bot.agents"
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
  })
})
