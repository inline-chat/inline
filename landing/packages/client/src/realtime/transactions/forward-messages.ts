import type {
  ForwardMessagesInput,
  InputPeer,
  RpcCall,
  RpcResult,
} from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import { protocolId, type ChatID, type MessageID } from "@inline/ids"
import type { Db } from "../../database"
import { applyUpdates } from "../updates"
import { Mutation, type Transaction } from "./transaction"

export type ForwardMessagesContext = {
  fromChatId: ChatID
  fromPeerId?: InputPeer
  toPeerId?: InputPeer
  messageIds: readonly MessageID[]
  shareForwardHeader?: boolean
}

export class ForwardMessagesTransaction
  implements Transaction<ForwardMessagesContext> {
  readonly method = Method.FORWARD_MESSAGES
  readonly kind = Mutation({ transient: true })
  readonly context: ForwardMessagesContext

  constructor(context: ForwardMessagesContext) {
    if (
      BigInt(context.fromChatId) <= 0n ||
      context.messageIds.length === 0 ||
      context.messageIds.length > 100 ||
      context.messageIds.some((id) => BigInt(id) <= 0n)
    ) {
      throw new TypeError("Invalid Inline forward request")
    }
    this.context = {
      ...context,
      messageIds: [...new Set(context.messageIds)],
    }
  }

  input(context: ForwardMessagesContext) {
    const payload: ForwardMessagesInput = {
      fromPeerId: context.fromPeerId,
      toPeerId: context.toPeerId,
      messageIds: context.messageIds.map(protocolId),
      shareForwardHeader: context.shareForwardHeader,
    }
    const input: RpcCall["input"] = {
      oneofKind: "forwardMessages",
      forwardMessages: payload,
    }
    return input
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "forwardMessages") {
      throw new Error("invalid")
    }
    applyUpdates(db, result.forwardMessages.updates)
  }
}

export const forwardMessages = (context: ForwardMessagesContext) =>
  new ForwardMessagesTransaction(context)
