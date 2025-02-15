import { db } from "@in/server/db"
import { asc, desc, eq } from "drizzle-orm"
import { files, messages } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Optional, type Static, Type } from "@sinclair/typebox"
import { encodeMessageInfo, TInputPeerInfo, TMessageInfo } from "@in/server/api-types"
import { getChatIdFromPeer } from "./sendMessage"
import { normalizeId, TInputId } from "@in/server/types/methods"

export const Input = Type.Object({
  peerId: Optional(TInputPeerInfo),
  peerUserId: Optional(TInputId),
  peerThreadId: Optional(TInputId),

  limit: Type.Optional(Type.Integer({ default: 70 })),
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Object({
  messages: Type.Array(TMessageInfo),
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  const peerId = input.peerUserId
    ? { userId: normalizeId(input.peerUserId) }
    : input.peerThreadId
    ? { threadId: normalizeId(input.peerThreadId) }
    : input.peerId

  if (!peerId) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  const chatId = await getChatIdFromPeer(peerId, context)

  if (isNaN(chatId)) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  const result = await db
    .select({
      message: messages,
      file: files,
    })
    .from(messages)
    .where(eq(messages.chatId, chatId))
    .leftJoin(files, eq(files.id, messages.fileId))
    .orderBy(desc(messages.date))
    .limit(input.limit ?? 70)

  const messages_ = result.map((m) =>
    encodeMessageInfo(m.message, {
      currentUserId: context.currentUserId,
      peerId: peerId,
      files: m.file ? [m.file] : null,
    }),
  )

  return {
    messages: messages_,
  }
}
