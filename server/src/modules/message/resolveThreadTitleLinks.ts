import { createChat } from "@in/server/functions/messages.createChat"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { chats } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { MessageEntity_Type, type MessageEntities, type MessageEntity } from "@inline-chat/protocol/core"
import { and, asc, eq, isNull, sql } from "drizzle-orm"

const MAX_THREAD_TITLE_LENGTH = 150

export async function resolveThreadTitleLinks(input: {
  entities: MessageEntities | undefined
  context: FunctionContext
}): Promise<MessageEntities | undefined> {
  const entities = input.entities
  if (!entities || entities.entities.length === 0) {
    return entities
  }

  let changed = false
  const resolved: MessageEntity[] = []

  for (const entity of entities.entities) {
    if (!entity) {
      changed = true
      continue
    }

    if (entity.type !== MessageEntity_Type.THREAD_TITLE) {
      resolved.push(entity)
      continue
    }

    if (entity.entity.oneofKind !== "threadTitle") {
      throw RealtimeRpcError.BadRequest()
    }

    const target = normalizeThreadTitleTarget(entity.entity.threadTitle)
    const chatId = await resolveOrCreateThreadByTitle({
      ...target,
      context: input.context,
    })

    changed = true
    resolved.push({
      ...entity,
      type: MessageEntity_Type.THREAD,
      entity: {
        oneofKind: "thread",
        thread: { chatId: BigInt(chatId) },
      },
    })
  }

  return changed ? { entities: resolved } : entities
}

async function resolveOrCreateThreadByTitle(input: {
  spaceId: number | null
  title: string
  context: FunctionContext
}): Promise<number> {
  if (input.spaceId !== null) {
    const existing = await findThreadByTitle(input.spaceId, input.title)
    if (existing) {
      await AccessGuards.ensureChatAccess(existing, input.context.currentUserId)
      return existing.id
    }

    const created = await createChat(
      {
        title: input.title,
        spaceId: BigInt(input.spaceId),
        isPublic: true,
      },
      input.context,
    )

    return Number(created.chat.id)
  }

  const existing = await findHomeThreadByTitle(input.context.currentUserId, input.title)
  if (existing) {
    await AccessGuards.ensureChatAccess(existing, input.context.currentUserId)
    return existing.id
  }

  const created = await createChat(
    {
      title: input.title,
      isPublic: false,
      participants: [{ userId: BigInt(input.context.currentUserId) }],
    },
    input.context,
  )

  return Number(created.chat.id)
}

async function findThreadByTitle(spaceId: number, title: string) {
  const titleLower = title.toLowerCase()
  const [chat] = await db
    .select()
    .from(chats)
    .where(
      and(
        eq(chats.type, "thread"),
        eq(chats.spaceId, spaceId),
        sql`lower(trim(${chats.title})) = ${titleLower}`,
      ),
    )
    .orderBy(asc(chats.id))
    .limit(1)

  return chat ?? null
}

async function findHomeThreadByTitle(ownerUserId: number, title: string) {
  const titleLower = title.toLowerCase()
  const [chat] = await db
    .select()
    .from(chats)
    .where(
      and(
        eq(chats.type, "thread"),
        isNull(chats.spaceId),
        eq(chats.createdBy, ownerUserId),
        sql`lower(trim(${chats.title})) = ${titleLower}`,
      ),
    )
    .orderBy(asc(chats.id))
    .limit(1)

  return chat ?? null
}

function normalizeThreadTitleTarget(input: { spaceId: bigint; title: string }): { spaceId: number | null; title: string } {
  const spaceId = Number(input.spaceId)
  const title = input.title.trim()

  if (!Number.isSafeInteger(spaceId) || spaceId < 0 || !title || title.length > MAX_THREAD_TITLE_LENGTH) {
    throw RealtimeRpcError.BadRequest()
  }

  return { spaceId: spaceId === 0 ? null : spaceId, title }
}
