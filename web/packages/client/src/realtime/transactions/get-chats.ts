import { GetChatsInput, Method, type RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import { Query } from "./transaction"
import type { Transaction } from "./transaction"
import { upsertChat, upsertDialog, upsertMessage, upsertSpace, upsertUser } from "./mappers"
import { putDialogFolder } from "../updates/dialog-state"

export type GetChatsContext = {}

export class GetChatsTransaction implements Transaction<GetChatsContext> {
  readonly method = Method.GET_CHATS
  readonly kind = Query()
  readonly context: GetChatsContext = {}

  input(_context: GetChatsContext): { oneofKind: "getChats"; getChats: GetChatsInput } {
    return { oneofKind: "getChats", getChats: GetChatsInput.create() }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
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

      for (const space of payload.spaces) {
        upsertSpace(db, space)
      }

      // Personal folders: the list is complete, so folders not in it are gone.
      const folderIds = new Set(payload.folders.map((folder) => String(folder.id)))
      for (const stored of db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DialogFolder,
        (folder) => !folderIds.has(folder.id),
      )) {
        db.delete(db.ref(DbObjectKind.DialogFolder, stored.id))
      }
      for (const folder of payload.folders) {
        putDialogFolder(db, folder)
      }

      for (const message of payload.messages) {
        upsertMessage(db, message)
      }
    })
  }
}

export const getChats = () => new GetChatsTransaction()
