import { describe, expect, it } from "bun:test"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { validateAgentThreadContext } from "@in/server/modules/agentConfiguration"
import { setupTestLifecycle, testUtils } from "../setup"

describe("agent thread binding authority", () => {
  setupTestLifecycle()

  const createBot = async (creatorId: number, username: string) => {
    const [bot] = await db.insert(users).values({ bot: true, botCreatorId: creatorId, username, firstName: username }).returning()
    if (!bot) throw new Error("Failed to create bot")
    return bot
  }

  it("lets owners and same-owner bots bind, and rejects other users' bots", async () => {
    const owner = await testUtils.createUser("binding-owner@example.com")
    const attacker = await testUtils.createUser("binding-attacker@example.com")
    const ownerCodex = await createBot(owner.id, "ownercodexbot")
    const ownerClaude = await createBot(owner.id, "ownerclaudebot")
    const attackerBot = await createBot(attacker.id, "attackerbot")
    const bind = (botUserId: number, actorId: number) => validateAgentThreadContext(
      { botUserId: BigInt(botUserId) },
      { operation: "create_chat", bindingActorUserId: actorId },
    )

    await expect(bind(ownerCodex.id, owner.id)).resolves.toBeDefined()
    await expect(bind(ownerCodex.id, ownerCodex.id)).resolves.toBeDefined()
    await expect(bind(ownerCodex.id, ownerClaude.id)).resolves.toBeDefined()
    await expect(bind(ownerCodex.id, attackerBot.id)).rejects.toThrow()
    await expect(bind(ownerCodex.id, attacker.id)).rejects.toThrow()
  })
})
