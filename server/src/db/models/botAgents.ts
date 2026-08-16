import { db } from "@in/server/db"
import { botAgents, type DbBotAgent } from "@in/server/db/schema"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import type { BotAgent } from "@inline-chat/protocol/core"
import { asc, eq } from "drizzle-orm"

type CreateBotAgent = {
  botUserId: number
  name: string
  handle?: string
  emoji?: string
  description?: string
  skillKey?: string
  instructions?: string
}

const optionalText = (value: string | undefined): string | undefined => {
  const trimmed = value?.trim()
  return trimmed ? trimmed : undefined
}

const encode = (row: DbBotAgent): BotAgent => ({
  id: BigInt(row.id),
  botUserId: BigInt(row.botUserId),
  name: row.name,
  handle: row.handle ?? undefined,
  emoji: row.emoji ?? undefined,
  description: row.description ?? undefined,
  skillKey: row.skillKey ?? undefined,
  instructions: row.instructionsEncrypted
    ? Encryption2.decryptToString(row.instructionsEncrypted)
    : undefined,
})

const create = async (input: CreateBotAgent): Promise<BotAgent> => {
  const instructions = optionalText(input.instructions)
  const [row] = await db
    .insert(botAgents)
    .values({
      botUserId: input.botUserId,
      name: input.name.trim(),
      handle: optionalText(input.handle),
      emoji: optionalText(input.emoji),
      description: optionalText(input.description),
      skillKey: optionalText(input.skillKey),
      instructionsEncrypted: instructions
        ? Encryption2.encrypt(Buffer.from(instructions, "utf8"))
        : null,
    })
    .returning()
  if (!row) throw new Error("bot agent insert returned no row")
  return encode(row)
}

const get = async (agentId: number): Promise<BotAgent | undefined> => {
  const [row] = await db.select().from(botAgents).where(eq(botAgents.id, agentId)).limit(1)
  return row ? encode(row) : undefined
}

const list = async (botUserId: number): Promise<BotAgent[]> => {
  const rows = await db
    .select()
    .from(botAgents)
    .where(eq(botAgents.botUserId, botUserId))
    .orderBy(asc(botAgents.id))
  return rows.map(encode)
}

export const BotAgentsModel = { create, get, list }
