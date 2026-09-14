import type { GetChatHistoryInput, InputPeer, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import {
  GetChatHistoryMode,
  Method,
} from "@inline-chat/protocol/core"
import type { ChatID, MessageID } from "@inline/ids"
import type { Db } from "../../database"
import {
  DbObjectKind,
  messageKey,
  type MessageKey,
} from "../../database/models"
import { messageModel, upsertMessage } from "./mappers"
import { Query, type Transaction } from "./transaction"
import { toBigInt } from "./helpers"

export type GetChatHistoryContext = {
  peerId?: InputPeer
  limit?: number
  mode?: GetChatHistoryMode
  beforeId?: MessageID
  afterId?: MessageID
  anchorId?: MessageID
  beforeLimit?: number
  afterLimit?: number
  includeAnchor?: boolean
}

export class GetChatHistoryTransaction implements Transaction<GetChatHistoryContext> {
  readonly method = Method.GET_CHAT_HISTORY
  readonly kind = Query()
  readonly context: GetChatHistoryContext
  private messageWindowIntents = new Map<ChatID, number>()

  constructor(context: GetChatHistoryContext) {
    this.context = context
  }

  input(context: GetChatHistoryContext) {
    const payload: GetChatHistoryInput = {
      peerId: context.peerId,
      limit: context.limit,
      mode: context.mode,
      beforeId: toBigInt(context.beforeId),
      afterId: toBigInt(context.afterId),
      anchorId: toBigInt(context.anchorId),
      beforeLimit: context.beforeLimit,
      afterLimit: context.afterLimit,
      includeAnchor: context.includeAnchor,
    }

    const input: RpcCall["input"] = { oneofKind: "getChatHistory", getChatHistory: payload }
    return input
  }

  beforeExecute(db: Db) {
    this.messageWindowIntents = db.captureResidentMessageWindowIntents()
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getChatHistory") {
      throw new Error("invalid")
    }

    db.batch(() => {
      for (const message of result.getChatHistory.messages) {
        upsertMessage(db, message)
      }
    })
  }

  afterCommit(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getChatHistory") return
    const keysByChat = new Map<ChatID, MessageKey[]>()
    for (const message of result.getChatHistory.messages) {
      const model = messageModel(message)
      const keys = keysByChat.get(model.chatId) ?? []
      keys.push(model.id)
      keysByChat.set(model.chatId, keys)
    }

    for (const [chatId, keys] of keysByChat) {
      const intentVersion = this.messageWindowIntents.get(chatId)
      if (intentVersion == null) continue
      if (
        this.context.mode == null ||
        this.context.mode ===
          GetChatHistoryMode.HISTORY_MODE_LATEST
      ) {
        db.replaceResidentMessageWindowWithLatest(
          chatId,
          keys,
          intentVersion,
        )
        continue
      }
      if (
        this.context.mode ===
        GetChatHistoryMode.HISTORY_MODE_AROUND
      ) {
        db.replaceResidentMessageWindow(
          chatId,
          keys,
          false,
          intentVersion,
        )
        continue
      }
      db.extendResidentMessageWindow(
        chatId,
        keys,
        intentVersion,
      )
      const chat = db.get(db.ref(DbObjectKind.Chat, chatId))
      if (
        chat?.lastMsgId != null &&
        keys.includes(messageKey(chatId, chat.lastMsgId))
      ) {
        db.setResidentMessageWindowAtLatest(
          chatId,
          intentVersion,
        )
      }
    }
  }
}

export const getChatHistory = (context: GetChatHistoryContext) => new GetChatHistoryTransaction(context)

export { GetChatHistoryMode }
