import { GetChatsInput, Method, type RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { Query } from "./transaction"
import type { Transaction } from "./transaction"
import { upsertChat, upsertDialog, upsertMessage, upsertUser } from "./mappers"

export type GetChatsContext = {}

export class GetChatsTransaction implements Transaction<GetChatsContext> {
  readonly method = Method.GET_CHATS
  readonly kind = Query()
  readonly context: GetChatsContext = {}

  input(_context: GetChatsContext): { oneofKind: "getChats"; getChats: GetChatsInput } {
    return { oneofKind: "getChats", getChats: GetChatsInput.create() }
  }

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getChats") {
      throw new Error("invalid")
    }

    const payload = result.getChats

    db.batch(() => {
      for (const user of payload.users) {
        upsertUser(db, user)
      }

      for (const chat of payload.chats) {
        upsertChat(db, chat)
      }

      for (const dialog of payload.dialogs) {
        upsertDialog(db, dialog)
      }

      for (const message of payload.messages) {
        upsertMessage(db, message)
      }
    })
  }
}

export const getChats = () => new GetChatsTransaction()
