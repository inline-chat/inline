import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { MessageEntities, RichMessage, UpdateComposeAction_ComposeAction } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { FileModel, type DbFullDocument, type DbFullPhoto } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { db } from "@in/server/db"
import { messages, type DbChat, type DbMessage } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { encryptBinary } from "@in/server/modules/encryption/encryption"
import { processOutgoingText } from "@in/server/modules/message/processOutgoingText"
import { resolveRichMediaPublicUrls, shouldResolveRichMediaUploads } from "@in/server/modules/mediaUploader"
import { validateInternalRichMediaRefs } from "@in/server/modules/message/richMediaValidation"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "@in/server/modules/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { eq } from "drizzle-orm"

export type InternalBotMessageInput = {
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly text: string
  readonly richText?: RichMessage
  readonly allowThinking?: boolean
  readonly resolveRichMedia?: boolean
  readonly replyToMsgId?: number | null
  readonly media?: InternalBotMessageMedia
}

export type InternalBotMessageMedia =
  | {
      readonly type: "photo"
      readonly photoId: number
    }
  | {
      readonly type: "document"
      readonly documentId: number
    }

export async function sendInternalBotMessage(input: InternalBotMessageInput): Promise<DbMessage> {
  const chat = await ChatModel.getChatFromInputPeer(input.inputPeer, { currentUserId: input.actorUserId })
  await AccessGuards.ensureChatAccess(chat, input.actorUserId)

  const processed = await processBotText({
    text: input.text,
    richText: input.richText,
    allowThinking: input.allowThinking,
    resolveRichMedia: input.resolveRichMedia,
    userId: input.botUserId,
  })
  const { message, update } = await MessageModel.insertMessage({
    chatId: chat.id,
    fromId: input.botUserId,
    textEncrypted: processed.encryptedText?.encrypted ?? null,
    textIv: processed.encryptedText?.iv ?? null,
    textTag: processed.encryptedText?.authTag ?? null,
    replyToMsgId: input.replyToMsgId ?? null,
    date: new Date(),
    mediaType: input.media?.type ?? null,
    photoId: input.media?.type === "photo" ? input.media.photoId : null,
    documentId: input.media?.type === "document" ? input.media.documentId : null,
    entitiesEncrypted: processed.encryptedEntities?.encrypted ?? null,
    entitiesIv: processed.encryptedEntities?.iv ?? null,
    entitiesTag: processed.encryptedEntities?.authTag ?? null,
    richTextEncrypted: processed.encryptedRichText?.encrypted ?? null,
    richTextIv: processed.encryptedRichText?.iv ?? null,
    richTextTag: processed.encryptedRichText?.authTag ?? null,
    richTextIndex: processed.richText ?? null,
  })
  const media = await resolveMessageMedia(input.media)

  const updateGroup = await getUpdateGroupFromInputPeer(input.inputPeer, { currentUserId: input.actorUserId })
  pushNewMessageUpdate({
    inputPeer: input.inputPeer,
    chat,
    message,
    botUserId: input.botUserId,
    actorUserId: input.actorUserId,
    updateGroup,
    media,
    update: {
      date: encodeDateStrict(update.date),
      seq: update.seq,
    },
  })

  return message
}

export async function editInternalBotMessage(input: {
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly outputMsgGlobalId: bigint
  readonly text: string
  readonly richText?: RichMessage
  readonly allowThinking?: boolean
  readonly resolveRichMedia?: boolean
}): Promise<void> {
  const current = await findMessageByGlobalId(input.outputMsgGlobalId)
  if (!current || current.fromId !== input.botUserId) {
    return
  }

  const processed = await processOutgoingText(
    input.richText
      ? {
          text: input.text,
          entities: undefined,
          richText: input.richText,
          allowThinking: input.allowThinking,
        }
      : { text: input.text, entities: undefined, parseRichMarkdown: true },
  )
  const shouldResolveMedia = input.resolveRichMedia ?? true
  const richText = processed.richText && shouldResolveMedia && shouldResolveRichMediaUploads()
    ? (await resolveRichMediaPublicUrls({ richText: processed.richText, userId: input.botUserId })).richText
    : processed.richText
  await validateInternalRichMediaRefs(richText, { ownerUserId: input.botUserId })
  const { message, update } = await MessageModel.editMessage({
    chatId: current.chatId,
    messageId: current.messageId,
    text: processed.text,
    entities: processed.entities,
    richText: richText ?? null,
  })

  const updateGroup = await getUpdateGroupFromInputPeer(input.inputPeer, { currentUserId: input.actorUserId })
  pushEditMessageUpdate({
    inputPeer: input.inputPeer,
    message,
    botUserId: input.botUserId,
    actorUserId: input.actorUserId,
    updateGroup,
    update: {
      date: encodeDateStrict(update.date),
      seq: update.seq,
    },
  })
}

export async function sendInternalTyping(input: {
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly typing: boolean
}): Promise<void> {
  await ChatModel.getChatFromInputPeer(input.inputPeer, { currentUserId: input.actorUserId })
  const updateGroup = await getUpdateGroupFromInputPeer(input.inputPeer, { currentUserId: input.actorUserId })
  const action = input.typing ? UpdateComposeAction_ComposeAction.TYPING : UpdateComposeAction_ComposeAction.NONE

  for (const userId of updateGroup.userIds) {
    if (userId === input.botUserId) {
      continue
    }

    RealtimeUpdates.pushToUser(userId, [
      {
        update: {
          oneofKind: "updateComposeAction",
          updateComposeAction: {
            userId: BigInt(input.botUserId),
            peerId: encodePeerFromInputPeer({
              inputPeer: peerForTarget({
                inputPeer: input.inputPeer,
                targetUserId: userId,
                actorUserId: input.actorUserId,
                botUserId: input.botUserId,
              }),
              currentUserId: userId,
            }),
            action,
          },
        },
      },
    ])
  }
}

async function processBotText(input: {
  readonly text: string
  readonly richText?: RichMessage
  readonly allowThinking?: boolean
  readonly resolveRichMedia?: boolean
  readonly userId: number
}): Promise<{
  readonly encryptedText?: ReturnType<typeof encryptMessage>
  readonly encryptedEntities?: ReturnType<typeof encryptBinary>
  readonly encryptedRichText?: ReturnType<typeof encryptBinary>
  readonly richText?: RichMessage
}> {
  const processed = await processOutgoingText(
    input.richText
      ? {
          text: input.text,
          entities: undefined,
          richText: input.richText,
          allowThinking: input.allowThinking,
        }
      : { text: input.text, entities: undefined, parseRichMarkdown: true },
  )
  const shouldResolveMedia = input.resolveRichMedia ?? true
  const richText = processed.richText && shouldResolveMedia && shouldResolveRichMediaUploads()
    ? (await resolveRichMediaPublicUrls({ richText: processed.richText, userId: input.userId })).richText
    : processed.richText
  await validateInternalRichMediaRefs(richText, { ownerUserId: input.userId })
  const encryptedText = processed.text ? encryptMessage(processed.text) : undefined
  const binaryEntities = processed.entities ? MessageEntities.toBinary(processed.entities) : undefined
  const encryptedEntities = binaryEntities && binaryEntities.length > 0 ? encryptBinary(binaryEntities) : undefined
  const binaryRichText = richText ? RichMessage.toBinary(richText) : undefined
  const encryptedRichText = binaryRichText && binaryRichText.length > 0 ? encryptBinary(binaryRichText) : undefined

  return { encryptedText, encryptedEntities, encryptedRichText, richText }
}

async function resolveMessageMedia(media: InternalBotMessageMedia | undefined): Promise<{
  readonly photo?: DbFullPhoto
  readonly document?: DbFullDocument
}> {
  if (!media) {
    return {}
  }

  if (media.type === "photo") {
    const photo = await FileModel.getPhotoById(BigInt(media.photoId)).catch(() => undefined)
    return photo ? { photo } : {}
  }

  const document = await FileModel.getDocumentById(BigInt(media.documentId)).catch(() => undefined)
  return document ? { document } : {}
}

async function findMessageByGlobalId(globalId: bigint): Promise<DbMessage | undefined> {
  const [row] = await db.select().from(messages).where(eq(messages.globalId, globalId)).limit(1)
  return row
}

function pushNewMessageUpdate(input: {
  readonly inputPeer: InputPeer
  readonly chat: DbChat
  readonly message: DbMessage
  readonly actorUserId: number
  readonly botUserId: number
  readonly updateGroup: UpdateGroup
  readonly media: {
    readonly photo?: DbFullPhoto
    readonly document?: DbFullDocument
  }
  readonly update: Pick<Update, "date" | "seq">
}): void {
  for (const userId of input.updateGroup.userIds) {
    const encoded = Encoders.message({
      message: input.message,
      encodingForPeer: {
        inputPeer: peerForTarget({
          inputPeer: input.inputPeer,
          targetUserId: userId,
          actorUserId: input.actorUserId,
          botUserId: input.botUserId,
        }),
      },
      encodingForUserId: userId,
      photo: input.media.photo,
      document: input.media.document,
    })

    RealtimeUpdates.pushToUser(userId, [
      {
        date: input.update.date,
        seq: input.update.seq,
        update: {
          oneofKind: "newMessage",
          newMessage: { message: encoded },
        },
      },
    ])
  }
}

function pushEditMessageUpdate(input: {
  readonly inputPeer: InputPeer
  readonly message: DbMessage
  readonly actorUserId: number
  readonly botUserId: number
  readonly updateGroup: UpdateGroup
  readonly update: Pick<Update, "date" | "seq">
}): void {
  for (const userId of input.updateGroup.userIds) {
    const encoded = Encoders.message({
      message: input.message,
      encodingForPeer: {
        inputPeer: peerForTarget({
          inputPeer: input.inputPeer,
          targetUserId: userId,
          actorUserId: input.actorUserId,
          botUserId: input.botUserId,
        }),
      },
      encodingForUserId: userId,
    })

    RealtimeUpdates.pushToUser(userId, [
      {
        date: input.update.date,
        seq: input.update.seq,
        update: {
          oneofKind: "editMessage",
          editMessage: { message: encoded },
        },
      },
    ])
  }
}

function peerForTarget(input: {
  readonly inputPeer: InputPeer
  readonly targetUserId: number
  readonly actorUserId: number
  readonly botUserId: number
}): InputPeer {
  if (input.inputPeer.type.oneofKind !== "user") {
    return input.inputPeer
  }

  return {
    type: {
      oneofKind: "user",
      user: {
        userId: BigInt(input.targetUserId === input.botUserId ? input.actorUserId : input.botUserId),
      },
    },
  }
}
