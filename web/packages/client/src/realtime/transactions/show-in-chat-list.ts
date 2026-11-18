import type {
  InputPeer,
  RpcCall,
  RpcResult,
  ShowInChatListInput,
} from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import { chatId } from "@inline/ids"
import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import { Mutation, type Transaction } from "./transaction"
import { upsertChat, upsertDialog } from "./mappers"

export type ShowInChatListContext = {
  peerId: InputPeer
}

const peerThreadId = (peer: InputPeer) =>
  peer.type.oneofKind === "chat" ? chatId(peer.type.chat.chatId) : undefined

export class ShowInChatListTransaction
  implements Transaction<ShowInChatListContext>
{
  readonly method = Method.SHOW_IN_CHAT_LIST
  readonly kind = Mutation({
    retryAfterTransportLoss: true,
    retryAfterAck: true,
  })
  readonly persistence = {
    type: "show_in_chat_list",
    replayPolicy: "idempotent" as const,
  }
  readonly context: ShowInChatListContext

  constructor(context: ShowInChatListContext) {
    this.context = context
  }

  input(context: ShowInChatListContext) {
    const payload: ShowInChatListInput = { peerId: context.peerId }
    const input: RpcCall["input"] = {
      oneofKind: "showInChatList",
      showInChatList: payload,
    }
    return input
  }

  optimistic(db: Db) {
    const threadId = peerThreadId(this.context.peerId)
    if (threadId == null) return

    const dialogs = db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.Dialog,
      (dialog) =>
        dialog.peerThreadId === threadId || dialog.chatId === threadId,
    )
    for (const dialog of dialogs) {
      db.replace({ ...dialog, chatListHidden: undefined })
    }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "showInChatList") {
      throw new Error("invalid")
    }
    if (!result.showInChatList.chat || !result.showInChatList.dialog) {
      throw new Error("invalid")
    }

    upsertChat(db, result.showInChatList.chat)
    upsertDialog(db, result.showInChatList.dialog)
  }
}

export const showInChatList = (context: ShowInChatListContext) =>
  new ShowInChatListTransaction(context)
