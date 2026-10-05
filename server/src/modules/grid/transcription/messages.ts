import { db } from "@in/server/db"
import { registerPostCommitHook } from "@in/server/db/commitHooks"
import { ChatModel } from "@in/server/db/models/chats"
import { ModelError } from "@in/server/db/models/_errors"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { chats, messages, users, UpdateBucket, type DbMessage } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { encryptBinary } from "@in/server/modules/encryption/encryption"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { publishDurableReference } from "@in/server/modules/internalMessaging/durable"
import { encryptSystemMessagePayload, type SystemMessage } from "@in/server/modules/systemMessages/payload"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { GridTranscriptMessageKind, MessageEntities } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"
import { getMessageThreadProjectionsMap } from "@in/server/modules/subthreads"

export type InsertGridTranscriptMessageInput = {
  chatId: number
  actorUserId: number
  runId: string
  segmentId: string
  speakerUserId?: number
  kind: GridTranscriptMessageKind | "turn" | "started" | "stopped" | "interrupted" | "link"
  /** Speech content for turns; lifecycle/link fallback content otherwise. */
  text: string
  entities?: MessageEntities
  date?: Date
}

export type InsertGridTranscriptMessageResult = {
  message: DbMessage & { systemMessage: SystemMessage }
  update: UpdateSeqAndDate
}

/**
 * Insert into ordinary encrypted history in the caller's transaction. The run
 * owner validates admission and deduplicates before calling this helper.
 * Generated content advances history, never sidebar activity or normal sends.
 */
export async function insertGridTranscriptMessage(
  tx: Transaction,
  input: InsertGridTranscriptMessageInput,
): Promise<InsertGridTranscriptMessageResult> {
  const [chat] = await tx.select().from(chats).where(eq(chats.id, input.chatId)).for("update").limit(1)
  if (!chat) throw ModelError.ChatInvalid
  const kind = typeof input.kind === "number" ? input.kind : {
    turn: GridTranscriptMessageKind.GRID_TRANSCRIPT_TURN,
    started: GridTranscriptMessageKind.GRID_TRANSCRIPT_STARTED,
    stopped: GridTranscriptMessageKind.GRID_TRANSCRIPT_STOPPED,
    interrupted: GridTranscriptMessageKind.GRID_TRANSCRIPT_INTERRUPTED,
    link: GridTranscriptMessageKind.GRID_TRANSCRIPT_LINK,
  }[input.kind]
  const systemMessage: SystemMessage = {
    event: {
      oneofKind: "gridTranscript",
      gridTranscript: {
        runId: input.runId,
        segmentId: input.segmentId,
        speakerUserId: input.speakerUserId === undefined ? undefined : BigInt(input.speakerUserId),
        kind,
      },
    },
  }
  const text = kind === GridTranscriptMessageKind.GRID_TRANSCRIPT_TURN
    ? `Transcript · ${await microphoneOwnerName(tx, input.speakerUserId)}: ${input.text}`
    : input.text
  const encryptedText = encryptMessage(text)
  const encryptedSystem = encryptSystemMessagePayload(systemMessage)
  const encryptedEntities = input.entities ? encryptBinary(MessageEntities.toBinary(input.entities)) : undefined
  const messageId = ChatModel.nextMessageId(chat)
  const [message] = await tx.insert(messages).values({
    chatId: chat.id,
    messageId,
    fromId: input.actorUserId,
    date: input.date ?? new Date(),
    textEncrypted: encryptedText.encrypted,
    textIv: encryptedText.iv,
    textTag: encryptedText.authTag,
    systemMessageEncrypted: encryptedSystem.encrypted,
    systemMessageIv: encryptedSystem.iv,
    systemMessageTag: encryptedSystem.authTag,
    entitiesEncrypted: encryptedEntities?.encrypted ?? null,
    entitiesIv: encryptedEntities?.iv ?? null,
    entitiesTag: encryptedEntities?.authTag ?? null,
    countsAsUnread: false,
    hasLink: false,
  }).returning()
  if (!message) throw ModelError.Failed
  const update = await UpdatesModel.insertUpdate(tx, {
    update: { oneofKind: "newMessage", newMessage: { chatId: BigInt(chat.id), msgId: BigInt(messageId) } },
    bucket: UpdateBucket.Chat,
    entity: chat,
  })
  await tx.update(chats).set({
    messageIdCounter: messageId,
    updateSeq: update.seq,
    lastUpdateDate: update.date,
  }).where(eq(chats.id, chat.id))
  const result = { message: { ...message, systemMessage }, update }
  registerPostCommitHook(tx, Symbol("grid-transcript-message"), {
    run: async () => { await publishGridTranscriptMessage(result) },
  })
  return result
}

/** Publish only after commit. Durable replay covers dropped best-effort hints. */
async function publishGridTranscriptMessage(input: InsertGridTranscriptMessageResult): Promise<void> {
  publishDurableReference({ bucket: { kind: "chat", chatId: input.message.chatId }, frontier: input.update.seq })
  // A delayed post-commit hint must not resurrect a row already cleared or
  // deleted. Replay represents that old sequence as a skipped message.
  const [current] = await db.select({ globalId: messages.globalId }).from(messages)
    .where(eq(messages.globalId, input.message.globalId)).limit(1)
  if (!current) return
  const access = await getEffectiveChatAccessUserIds(db, [input.message.chatId])
  await Promise.all(Array.from(access.get(input.message.chatId) ?? []).map(async (userId) => {
    const projection = (await getMessageThreadProjectionsMap({
      parentChatId: input.message.chatId, parentMessageIds: [input.message.messageId], userId,
    })).get(input.message.messageId)
    await RealtimeUpdates.pushToUser(userId, [{
      seq: input.update.seq,
      date: encodeDateStrict(input.update.date),
      update: {
        oneofKind: "newMessage",
        newMessage: {
          message: Encoders.message({
            message: input.message,
            encodingForUserId: userId,
            encodingForPeer: { peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(input.message.chatId) } } } },
            replies: projection?.replies,
            subthread: projection?.subthread,
          }),
        },
      },
    }])
  }))
}

async function microphoneOwnerName(tx: Transaction, userId: number | undefined): Promise<string> {
  if (userId === undefined) throw new Error("Transcript turn requires a microphone owner")
  const [user] = await tx.select({ firstName: users.firstName, lastName: users.lastName, username: users.username })
    .from(users).where(eq(users.id, userId)).limit(1)
  if (!user) throw ModelError.Failed
  return [user.firstName, user.lastName].filter(Boolean).join(" ").trim() || user.username || "Participant"
}
