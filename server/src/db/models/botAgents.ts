import { db } from "@in/server/db"
import { botAgents, type DbBotAgent } from "@in/server/db/schema"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import type { BotAgent, BotAgentProfile } from "@inline-chat/protocol/core"
import { asc, eq, inArray } from "drizzle-orm"

type CreateBotAgent = {
  botUserId: number
  name: string
  handle?: string
  emoji?: string
  description?: string
  skillKey?: string
  instructions?: string
}

type UpdateBotAgent = {
  agentId: number
  name?: string
  handle?: string | null
  emoji?: string | null
  description?: string | null
  skillKey?: string | null
  instructions?: string | null
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

const encodeProfile = (row: {
  id: number
  botUserId: number
  name: string
  handle: string | null
  emoji: string | null
  description: string | null
}): BotAgentProfile => ({
  id: BigInt(row.id),
  botUserId: BigInt(row.botUserId),
  name: row.name,
  handle: row.handle ?? undefined,
  emoji: row.emoji ?? undefined,
  description: row.description ?? undefined,
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

const getMany = async (agentIds: number[]): Promise<Map<number, BotAgent>> => {
  if (agentIds.length === 0) return new Map()
  const rows = await db.select().from(botAgents).where(inArray(botAgents.id, agentIds))
  return new Map(rows.map((row) => [row.id, encode(row)]))
}

const list = async (botUserId: number): Promise<BotAgent[]> => {
  const rows = await db
    .select()
    .from(botAgents)
    .where(eq(botAgents.botUserId, botUserId))
    .orderBy(asc(botAgents.id))
  return rows.map(encode)
}

const listProfilesForBotUserIds = async (
  botUserIds: number[],
): Promise<Map<number, BotAgentProfile[]>> => {
  const profilesByBotUserId = new Map<number, BotAgentProfile[]>()
  if (botUserIds.length === 0) return profilesByBotUserId

  const rows = await db
    .select({
      id: botAgents.id,
      botUserId: botAgents.botUserId,
      name: botAgents.name,
      handle: botAgents.handle,
      emoji: botAgents.emoji,
      description: botAgents.description,
    })
    .from(botAgents)
    .where(inArray(botAgents.botUserId, botUserIds))
    .orderBy(asc(botAgents.botUserId), asc(botAgents.id))

  for (const row of rows) {
    const profiles = profilesByBotUserId.get(row.botUserId) ?? []
    profiles.push(encodeProfile(row))
    profilesByBotUserId.set(row.botUserId, profiles)
  }
  return profilesByBotUserId
}

const update = async (input: UpdateBotAgent): Promise<BotAgent | undefined> => {
  const values: Partial<typeof botAgents.$inferInsert> = { updatedAt: new Date() }
  if (input.name !== undefined) values.name = input.name
  if (input.handle !== undefined) values.handle = input.handle
  if (input.emoji !== undefined) values.emoji = input.emoji
  if (input.description !== undefined) values.description = input.description
  if (input.skillKey !== undefined) values.skillKey = input.skillKey
  if (input.instructions !== undefined) {
    values.instructionsEncrypted = input.instructions
      ? Encryption2.encrypt(Buffer.from(input.instructions, "utf8"))
      : null
  }

  const [row] = await db
    .update(botAgents)
    .set(values)
    .where(eq(botAgents.id, input.agentId))
    .returning()
  return row ? encode(row) : undefined
}

const deleteAgent = async (agentId: number): Promise<boolean> => {
  const rows = await db.delete(botAgents).where(eq(botAgents.id, agentId)).returning({ id: botAgents.id })
  return rows.length > 0
}

export const BotAgentsModel = {
  create,
  delete: deleteAgent,
  get,
  getMany,
  list,
  listProfilesForBotUserIds,
  update,
}
