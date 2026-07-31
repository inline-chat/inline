import { beforeEach, describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import { createBot } from "@in/server/functions/createBot"
import { setBotCommands } from "@in/server/functions/bot.setCommands"
import { resolveBotCommandTargets } from "@in/server/modules/message/resolveBotCommandTargets"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"

const commandEntities = (text: string, botUserId?: number): MessageEntities => ({
  entities: [
    {
      type: MessageEntity_Type.BOT_COMMAND,
      offset: 0n,
      length: BigInt(text.length),
      entity: botUserId
        ? { oneofKind: "botCommand", botCommand: { botUserId: BigInt(botUserId) } }
        : { oneofKind: undefined },
    },
  ],
})

describe("bot command target resolution", () => {
  setupTestLifecycle()

  let creator: Awaited<ReturnType<typeof testUtils.createUser>>
  let chat: NonNullable<Awaited<ReturnType<typeof testUtils.createChat>>>
  let alphaBotUserId: number
  let betaBotUserId: number

  beforeEach(async () => {
    creator = await testUtils.createUser(`command-targets-${Date.now()}-${Math.random()}@example.com`)
    const context = { currentUserId: creator.id, currentSessionId: 1 }
    const alpha = await createBot(
      { name: "Alpha Agent", username: `alphaagent${creator.id}bot` },
      context,
    )
    const beta = await createBot(
      { name: "Beta Agent", username: `betaagent${creator.id}bot` },
      context,
    )
    alphaBotUserId = Number(alpha.bot?.id)
    betaBotUserId = Number(beta.bot?.id)
    await setBotCommands(
      {
        botUserId: BigInt(alphaBotUserId),
        commands: [
          { command: "alpha", description: "Alpha only" },
          { command: "help", description: "Help" },
        ],
      },
      context,
    )
    await setBotCommands(
      {
        botUserId: BigInt(betaBotUserId),
        commands: [
          { command: "beta", description: "Beta only" },
          { command: "help", description: "Help" },
        ],
      },
      context,
    )
    chat = (await testUtils.createChat(null, "Command targets", "thread", false, creator.id))!
    await testUtils.addParticipant(chat.id, creator.id)
    await testUtils.addParticipant(chat.id, alphaBotUserId)
    await testUtils.addParticipant(chat.id, betaBotUserId)
  })

  test("backfills the only bot advertising a range-only command", async () => {
    const entities = await resolveBotCommandTargets({
      text: "/alpha",
      entities: commandEntities("/alpha"),
      chat,
      currentUserId: creator.id,
    })

    expect(entities?.entities[0]?.entity).toEqual({
      oneofKind: "botCommand",
      botCommand: { botUserId: BigInt(alphaBotUserId) },
    })
  })

  test("keeps an ambiguous range-only command unresolved", async () => {
    const original = commandEntities("/help")
    const entities = await resolveBotCommandTargets({
      text: "/help",
      entities: original,
      chat,
      currentUserId: creator.id,
    })

    expect(entities).toBe(original)
    expect(entities?.entities[0]?.entity.oneofKind).toBeUndefined()
  })

  test("resolves a textual bot suffix and validates its catalog", async () => {
    const text = `/help@alphaagent${creator.id}bot`
    const entities = await resolveBotCommandTargets({
      text,
      entities: commandEntities(text),
      chat,
      currentUserId: creator.id,
    })

    expect(entities?.entities[0]?.entity).toEqual({
      oneofKind: "botCommand",
      botCommand: { botUserId: BigInt(alphaBotUserId) },
    })
  })

  test("rejects a structured target that does not advertise the command", async () => {
    await expect(
      resolveBotCommandTargets({
        text: "/alpha",
        entities: commandEntities("/alpha", betaBotUserId),
        chat,
        currentUserId: creator.id,
      }),
    ).rejects.toThrow()
  })
})
