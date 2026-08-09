import type {
  CreateSubthreadInput,
  RpcCall,
  RpcResult,
} from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import {
  chatId,
  protocolId,
  type ChatID,
  type MessageID,
  type UserID,
} from "@inline/ids"
import type { Db } from "../../database"
import { Mutation, type Transaction } from "./transaction"
import { upsertChat, upsertDialog, upsertMessage } from "./mappers"

export type CreateSubthreadContext = {
  parentChatId: ChatID
  parentMessageId?: MessageID
  title?: string
  description?: string
  emoji?: string
  participants?: readonly UserID[]
}

export class CreateSubthreadTransaction
  implements Transaction<CreateSubthreadContext> {
  readonly method = Method.CREATE_SUBTHREAD
  readonly kind = Mutation({ transient: true })
  readonly context: CreateSubthreadContext

  constructor(context: CreateSubthreadContext) {
    const participants = context.participants ?? []
    if (
      BigInt(context.parentChatId) <= 0n ||
      (context.parentMessageId != null &&
        BigInt(context.parentMessageId) <= 0n) ||
      participants.length > 100 ||
      participants.some((id) => BigInt(id) <= 0n) ||
      (context.title?.length ?? 0) > 1_024 ||
      (context.description?.length ?? 0) > 10_000 ||
      (context.emoji?.length ?? 0) > 64
    ) {
      throw new TypeError("Invalid Inline subthread request")
    }
    this.context = { ...context, participants: [...participants] }
  }

  input(context: CreateSubthreadContext) {
    const payload: CreateSubthreadInput = {
      parentChatId: protocolId(context.parentChatId),
      parentMessageId:
        context.parentMessageId == null
          ? undefined
          : protocolId(context.parentMessageId),
      title: context.title?.trim() || undefined,
      description: context.description?.trim() || undefined,
      emoji: context.emoji?.trim() || undefined,
      participants: (context.participants ?? []).map((userId) => ({
        userId: protocolId(userId),
      })),
    }
    const input: RpcCall["input"] = {
      oneofKind: "createSubthread",
      createSubthread: payload,
    }
    return input
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (
      !result ||
      result.oneofKind !== "createSubthread" ||
      !result.createSubthread.chat
    ) {
      throw new Error("invalid")
    }
    upsertChat(db, result.createSubthread.chat)
    if (result.createSubthread.dialog) {
      upsertDialog(db, result.createSubthread.dialog)
    }
    if (result.createSubthread.anchorMessage) {
      upsertMessage(db, result.createSubthread.anchorMessage)
    }
  }

  createdChatId(result: RpcResult["result"] | undefined): ChatID {
    if (
      !result ||
      result.oneofKind !== "createSubthread" ||
      !result.createSubthread.chat
    ) {
      throw new Error("invalid")
    }
    return chatId(result.createSubthread.chat.id)
  }
}

export const createSubthread = (context: CreateSubthreadContext) =>
  new CreateSubthreadTransaction(context)
