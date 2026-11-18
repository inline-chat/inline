import { Method, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { ChatID } from "@inline/ids"
import type { Db } from "../../database"
import { applyChatRoster, putUserGroup } from "../updates/membership"
import { upsertUser } from "./mappers"
import { Query, type Transaction } from "./transaction"

export type GetChatParticipantsContext = { chatId: ChatID }

/**
 * `GET_CHAT_PARTICIPANTS`: the chat's direct and group grants, with their
 * users and groups. It replaces the stored roster and marks it complete.
 */
export class GetChatParticipantsTransaction
  implements Transaction<GetChatParticipantsContext>
{
  readonly method = Method.GET_CHAT_PARTICIPANTS
  readonly kind = Query()

  constructor(readonly context: GetChatParticipantsContext) {}

  input(context: GetChatParticipantsContext): RpcCall["input"] {
    return {
      oneofKind: "getChatParticipants",
      getChatParticipants: { chatId: BigInt(context.chatId) },
    }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getChatParticipants") {
      throw new Error("invalid")
    }
    const { participants, users, groupParticipants, groups } =
      result.getChatParticipants
    db.batch(() => {
      for (const user of users) upsertUser(db, user)
      for (const group of groups) putUserGroup(db, group)
      applyChatRoster(db, this.context.chatId, participants, groupParticipants)
    })
  }
}

export const getChatParticipants = (context: GetChatParticipantsContext) =>
  new GetChatParticipantsTransaction(context)
