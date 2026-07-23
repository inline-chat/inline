import type { GetChatInput, InputPeer, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import { chatId, messageId } from "@inline/ids"
import type { Db } from "../../database"
import { upsertChat, upsertDialog } from "./mappers"
import { DbObjectKind } from "../../database/models"
import { Query, type Transaction } from "./transaction"

export type GetChatContext = {
  peerId?: InputPeer
}

export class GetChatTransaction implements Transaction<GetChatContext> {
  readonly method = Method.GET_CHAT
  readonly kind = Query()
  readonly context: GetChatContext

  constructor(context: GetChatContext) {
    this.context = context
  }

  input(context: GetChatContext) {
    const payload: GetChatInput = {
      peerId: context.peerId,
    }

    const input: RpcCall["input"] = { oneofKind: "getChat", getChat: payload }
    return input
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getChat") {
      throw new Error("invalid")
    }

    if (result.getChat.chat) {
      upsertChat(db, result.getChat.chat)
    }
    if (result.getChat.dialog) {
      upsertDialog(db, result.getChat.dialog)
    }

    const pinnedMessageIds = result.getChat.pinnedMessageIds
      .map((id) => messageId(id))

    const exactChatId =
      result.getChat.chat == null ? undefined : chatId(result.getChat.chat.id)
    if (exactChatId != null) {
      const ref = db.ref(DbObjectKind.Chat, exactChatId)
      const existing = db.get(ref)
      if (existing) {
        db.update({
          ...existing,
          pinnedMessageIds,
        })
      }
    }
  }
}

export const getChat = (context: GetChatContext) => new GetChatTransaction(context)
