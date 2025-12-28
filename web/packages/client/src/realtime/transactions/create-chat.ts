import type { CreateChatInput, InputChatParticipant, RpcCall, RpcResult } from "@in/protocol/core"
import { Method } from "@in/protocol/core"
import type { Db } from "../../database"
import { upsertChat, upsertDialog } from "./mappers"
import { Mutation, type Transaction } from "./transaction"
import { toBigInt } from "./helpers"

export type CreateChatContext = {
  title: string
  spaceId?: number
  description?: string
  emoji?: string
  isPublic: boolean
  participants?: InputChatParticipant[]
}

export class CreateChatTransaction implements Transaction<CreateChatContext> {
  readonly method = Method.CREATE_CHAT
  readonly kind = Mutation()
  readonly context: CreateChatContext

  constructor(context: CreateChatContext) {
    this.context = context
  }

  input(context: CreateChatContext) {
    const payload: CreateChatInput = {
      title: context.title,
      spaceId: toBigInt(context.spaceId),
      description: context.description,
      emoji: context.emoji,
      isPublic: context.isPublic,
      participants: context.participants ?? [],
    }

    const input: RpcCall["input"] = { oneofKind: "createChat", createChat: payload }
    return input
  }

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "createChat") {
      throw new Error("invalid")
    }

    if (result.createChat.chat) {
      upsertChat(db, result.createChat.chat)
    }
    if (result.createChat.dialog) {
      upsertDialog(db, result.createChat.dialog)
    }
  }
}

export const createChat = (context: CreateChatContext) => new CreateChatTransaction(context)
