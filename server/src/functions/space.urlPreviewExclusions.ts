import {
  type AddSpaceUrlPreviewExclusionInput,
  type AddSpaceUrlPreviewExclusionResult,
  type GetSpaceUrlPreviewExclusionsInput,
  type GetSpaceUrlPreviewExclusionsResult,
  type InputPeer,
  type MessageAttachment,
  type RemoveSpaceUrlPreviewExclusionInput,
  type RemoveSpaceUrlPreviewExclusionResult,
  type SpaceUrlPreviewExclusion,
  type Update,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import {
  chats,
  messageAttachments,
  messages,
  spaceUrlPreviewExclusions,
  urlPreview,
  type DbSpaceUrlPreviewExclusion,
} from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "@in/server/modules/updates"
import {
  exclusionMatchesTarget,
  normalizeSpaceUrlPreviewExclusion,
  urlPreviewExclusionTarget,
} from "@in/server/modules/urlPreview/exclusions"
import { Authorize } from "@in/server/utils/authorize"
import { encodeMessageAttachmentUpdate } from "@in/server/realtime/encoders/encodeMessageAttachment"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { and, asc, eq } from "drizzle-orm"

const log = new Log("functions.spaceUrlPreviewExclusions")

type DeletedPreviewAttachment = {
  attachmentId: number
  update: UpdateSeqAndDate
}

export async function getSpaceUrlPreviewExclusions(
  input: GetSpaceUrlPreviewExclusionsInput,
  context: FunctionContext,
): Promise<GetSpaceUrlPreviewExclusionsResult> {
  const spaceId = toPositiveSafeInteger(input.spaceId)
  await Authorize.spaceAdmin(spaceId, context.currentUserId)

  const rows = await db
    .select()
    .from(spaceUrlPreviewExclusions)
    .where(eq(spaceUrlPreviewExclusions.spaceId, spaceId))
    .orderBy(asc(spaceUrlPreviewExclusions.host), asc(spaceUrlPreviewExclusions.pathPrefix))

  return { exclusions: rows.map(encodeSpaceUrlPreviewExclusion) }
}

export async function addSpaceUrlPreviewExclusion(
  input: AddSpaceUrlPreviewExclusionInput,
  context: FunctionContext,
): Promise<AddSpaceUrlPreviewExclusionResult> {
  const spaceId = toPositiveSafeInteger(input.spaceId)
  await Authorize.spaceAdmin(spaceId, context.currentUserId)

  const normalized = normalizeSpaceUrlPreviewExclusion(input.host, input.pathPrefix)
  if (!normalized) {
    throw RealtimeRpcError.BadRequest()
  }

  if (!input.peerId && !input.messageId) {
    const exclusion = await insertSpaceUrlPreviewExclusion({
      spaceId,
      host: normalized.host,
      pathPrefix: normalized.pathPrefix,
      createdBy: context.currentUserId,
    })

    return {
      exclusion: encodeSpaceUrlPreviewExclusion(exclusion),
      updates: [],
    }
  }

  if (!input.peerId || !input.messageId) {
    throw RealtimeRpcError.BadRequest()
  }

  const messageId = toPositiveSafeInteger(input.messageId)
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  if (chat.spaceId !== spaceId) {
    throw RealtimeRpcError.BadRequest()
  }

  const { exclusion, deleted } = await db.transaction(async (tx) => {
    const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update").limit(1)
    if (lockedChat?.spaceId !== spaceId) {
      throw RealtimeRpcError.BadRequest()
    }

    const [message] = await tx
      .select()
      .from(messages)
      .where(and(eq(messages.chatId, chat.id), eq(messages.messageId, messageId)))
      .limit(1)
    if (!message) {
      throw RealtimeRpcError.MessageIdInvalid()
    }

    const attachmentRows = await tx
      .select({
        attachment: messageAttachments,
        preview: urlPreview,
      })
      .from(messageAttachments)
      .innerJoin(urlPreview, eq(messageAttachments.urlPreviewId, urlPreview.id))
      .where(eq(messageAttachments.messageId, message.globalId))

    const [inserted] = await tx
      .insert(spaceUrlPreviewExclusions)
      .values({
        spaceId,
        host: normalized.host,
        pathPrefix: normalized.pathPrefix,
        createdBy: context.currentUserId,
      })
      .onConflictDoNothing()
      .returning()

    let exclusion = inserted
    if (!exclusion) {
      const [existing] = await tx
        .select()
        .from(spaceUrlPreviewExclusions)
        .where(
          and(
            eq(spaceUrlPreviewExclusions.spaceId, spaceId),
            eq(spaceUrlPreviewExclusions.host, normalized.host),
            eq(spaceUrlPreviewExclusions.pathPrefix, normalized.pathPrefix),
          ),
        )
        .limit(1)
      if (!existing) {
        throw new Error("URL preview exclusion conflict returned no row")
      }
      exclusion = existing
    }

    const deleted: DeletedPreviewAttachment[] = []
    for (const row of attachmentRows) {
      const previewUrl = decryptPreviewUrl(row.preview)
      const target = previewUrl ? urlPreviewExclusionTarget(previewUrl) : null
      if (!target || !exclusionMatchesTarget(normalized, target)) {
        continue
      }

      await tx
        .delete(messageAttachments)
        .where(and(eq(messageAttachments.id, row.attachment.id), eq(messageAttachments.messageId, message.globalId)))

      const update = await UpdatesModel.insertUpdate(tx, {
        update: {
          oneofKind: "messageAttachment",
          messageAttachment: {
            chatId: BigInt(chat.id),
            msgId: BigInt(message.messageId),
            attachmentId: BigInt(row.attachment.id),
          },
        },
        bucket: UpdateBucket.Chat,
        entity: lockedChat,
      })

      deleted.push({ attachmentId: row.attachment.id, update })
    }

    const lastUpdate = deleted.at(-1)?.update
    if (lastUpdate) {
      await tx
        .update(chats)
        .set({
          updateSeq: lastUpdate.seq,
          lastUpdateDate: lastUpdate.date,
        })
        .where(eq(chats.id, chat.id))
    }

    return { exclusion, deleted }
  })

  const updates = await pushDeletedPreviewAttachmentUpdates({
    inputPeer: input.peerId,
    messageId,
    chatId: chat.id,
    currentUserId: context.currentUserId,
    deleted,
  })

  return {
    exclusion: encodeSpaceUrlPreviewExclusion(exclusion),
    updates,
  }
}

export async function removeSpaceUrlPreviewExclusion(
  input: RemoveSpaceUrlPreviewExclusionInput,
  context: FunctionContext,
): Promise<RemoveSpaceUrlPreviewExclusionResult> {
  const spaceId = toPositiveSafeInteger(input.spaceId)
  const exclusionId = toPositiveSafeInteger(input.exclusionId)
  await Authorize.spaceAdmin(spaceId, context.currentUserId)

  const [deleted] = await db
    .delete(spaceUrlPreviewExclusions)
    .where(and(eq(spaceUrlPreviewExclusions.id, exclusionId), eq(spaceUrlPreviewExclusions.spaceId, spaceId)))
    .returning({ id: spaceUrlPreviewExclusions.id })

  if (!deleted) {
    throw RealtimeRpcError.BadRequest()
  }

  return {}
}

async function insertSpaceUrlPreviewExclusion(input: {
  spaceId: number
  host: string
  pathPrefix: string
  createdBy: number
}): Promise<DbSpaceUrlPreviewExclusion> {
  const [inserted] = await db
    .insert(spaceUrlPreviewExclusions)
    .values(input)
    .onConflictDoNothing()
    .returning()

  if (inserted) {
    return inserted
  }

  const existing = await selectSpaceUrlPreviewExclusion(input.spaceId, input.host, input.pathPrefix, db)
  if (!existing) {
    throw new Error("URL preview exclusion conflict returned no row")
  }
  return existing
}

async function selectSpaceUrlPreviewExclusion(
  spaceId: number,
  host: string,
  pathPrefix: string,
  database: typeof db,
): Promise<DbSpaceUrlPreviewExclusion | null> {
  const [row] = await database
    .select()
    .from(spaceUrlPreviewExclusions)
    .where(
      and(
        eq(spaceUrlPreviewExclusions.spaceId, spaceId),
        eq(spaceUrlPreviewExclusions.host, host),
        eq(spaceUrlPreviewExclusions.pathPrefix, pathPrefix),
      ),
    )
    .limit(1)

  return row ?? null
}

function encodeSpaceUrlPreviewExclusion(row: DbSpaceUrlPreviewExclusion): SpaceUrlPreviewExclusion {
  return {
    id: BigInt(row.id),
    spaceId: BigInt(row.spaceId),
    host: row.host,
    pathPrefix: row.pathPrefix === "" ? undefined : row.pathPrefix,
    createdBy: BigInt(row.createdBy),
    date: encodeDateStrict(row.date),
  }
}

function decryptPreviewUrl(preview: {
  url: Buffer | null
  urlIv: Buffer | null
  urlTag: Buffer | null
}): string | null {
  if (!preview.url || !preview.urlIv || !preview.urlTag) {
    return null
  }

  try {
    return decryptMessage({
      encrypted: preview.url,
      iv: preview.urlIv,
      authTag: preview.urlTag,
    })
  } catch (error) {
    log.warn("Failed to decrypt URL preview while excluding domain", { error })
    return null
  }
}

function toPositiveSafeInteger(id: bigint): number {
  const value = Number(id)
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw RealtimeRpcError.BadRequest()
  }
  return value
}

async function pushDeletedPreviewAttachmentUpdates(input: {
  inputPeer: InputPeer
  messageId: number
  chatId: number
  currentUserId: number
  deleted: DeletedPreviewAttachment[]
}): Promise<Update[]> {
  if (input.deleted.length === 0) {
    return []
  }

  const updateGroup = await getUpdateGroupFromInputPeer(input.inputPeer, { currentUserId: input.currentUserId })
  const selfUpdates: Update[] = []

  for (const deleted of input.deleted) {
    const attachment: MessageAttachment = {
      id: BigInt(deleted.attachmentId),
      attachment: { oneofKind: undefined },
    }

    pushDeletedPreviewAttachmentUpdate({
      inputPeer: input.inputPeer,
      messageId: input.messageId,
      chatId: input.chatId,
      attachment,
      currentUserId: input.currentUserId,
      update: deleted.update,
      updateGroup,
      selfUpdates,
    })
  }

  return selfUpdates
}

function pushDeletedPreviewAttachmentUpdate(input: {
  inputPeer: InputPeer
  messageId: number
  chatId: number
  attachment: MessageAttachment
  currentUserId: number
  update: UpdateSeqAndDate
  updateGroup: UpdateGroup
  selfUpdates: Update[]
}) {
  input.updateGroup.userIds.forEach((userId) => {
    const encodingForInputPeer: InputPeer =
      input.updateGroup.type === "dmUsers" && userId !== input.currentUserId
        ? { type: { oneofKind: "user", user: { userId: BigInt(input.currentUserId) } } }
        : input.inputPeer

    const update = encodeMessageAttachmentUpdate({
      messageId: BigInt(input.messageId),
      chatId: BigInt(input.chatId),
      encodingForUserId: userId,
      encodingForPeer: { inputPeer: encodingForInputPeer },
      attachment: input.attachment,
      seq: input.update.seq,
      date: input.update.date,
    })

    RealtimeUpdates.pushToUser(userId, [update])
    if (userId === input.currentUserId) {
      input.selfUpdates.push(update)
    }
  })
}
