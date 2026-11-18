import type { GetChatHistoryInput, InputPeer, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import {
  GetChatHistoryMode,
  Method,
} from "@inline-chat/protocol/core"
import { chatId as makeChatId, type ChatID, type MessageID } from "@inline/ids"
import type { Db } from "../../database"
import {
  DbObjectKind,
  messageKey,
  type MessageKey,
} from "../../database/models"
import {
  provenRanges,
  type HistoryPageRequest,
} from "../../database/history-coverage"
import { dialogForPeer } from "./dialog-for-peer"
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
  /** The chat's newest known message when the request was made. */
  private knownMaxId: MessageID | undefined

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
    const chatId = this.chatId(db)
    this.knownMaxId =
      chatId == null
        ? undefined
        : db.get(db.ref(DbObjectKind.Chat, chatId))?.lastMsgId
  }

  /**
   * Store the page's rows and admit the history it proves, in the commit the
   * transaction runs in: rows and coverage commit or roll back together
   * (invariant 5). A page that does not match its request stores its rows
   * but certifies nothing.
   */
  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getChatHistory") {
      throw new Error("invalid")
    }

    db.batch(() => {
      for (const message of result.getChatHistory.messages) {
        upsertMessage(db, message)
      }
      const chatId = this.chatId(db)
      if (chatId == null) return
      const returned = result.getChatHistory.messages
      if (returned.some((message) => String(message.chatId) !== chatId)) {
        return
      }
      const ranges = provenRanges(
        this.pageRequest(),
        returned.map((message) => message.id),
      )
      if (!ranges) return
      db.admitHistoryPage(
        chatId,
        ranges,
        returned.map((message) => messageModel(message).messageId),
        this.knownMaxId,
      )
    })
  }

  private chatId(db: Db): ChatID | undefined {
    const peer = this.context.peerId
    if (!peer) return undefined
    if (peer.type.oneofKind === "chat") {
      return makeChatId(peer.type.chat.chatId)
    }
    return dialogForPeer(db, peer)?.chatId
  }

  private pageRequest(): HistoryPageRequest {
    const context = this.context
    const mode =
      context.mode === GetChatHistoryMode.HISTORY_MODE_OLDER
        ? "older"
        : context.mode === GetChatHistoryMode.HISTORY_MODE_NEWER
          ? "newer"
          : context.mode === GetChatHistoryMode.HISTORY_MODE_AROUND
            ? "around"
            : "latest"
    return {
      mode,
      ...(context.limit != null ? { limit: context.limit } : {}),
      ...(context.beforeId != null ? { beforeId: BigInt(context.beforeId) } : {}),
      ...(context.afterId != null ? { afterId: BigInt(context.afterId) } : {}),
      ...(context.anchorId != null ? { anchorId: BigInt(context.anchorId) } : {}),
      ...(context.beforeLimit != null ? { beforeLimit: context.beforeLimit } : {}),
      ...(context.afterLimit != null ? { afterLimit: context.afterLimit } : {}),
      ...(context.includeAnchor != null
        ? { includeAnchor: context.includeAnchor }
        : {}),
    }
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
