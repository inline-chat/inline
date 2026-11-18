import type {
  InputPeer,
  InvokeMessageActionInput,
  RpcCall,
  RpcResult,
} from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import { protocolId, type ChatID, type MessageID } from "@inline/ids"
import type { Db } from "../../database"
import { Mutation, type Transaction } from "./transaction"

export type InvokeMessageActionContext = {
  chatId: ChatID
  messageId: MessageID
  peerId?: InputPeer
  actionId: string
}

export class InvokeMessageActionTransaction
  implements Transaction<InvokeMessageActionContext> {
  readonly method = Method.INVOKE_MESSAGE_ACTION
  readonly kind = Mutation({ transient: true })
  readonly context: InvokeMessageActionContext

  constructor(context: InvokeMessageActionContext) {
    if (
      BigInt(context.chatId) <= 0n ||
      BigInt(context.messageId) <= 0n ||
      !context.actionId.trim() ||
      context.actionId.length > 256
    ) {
      throw new TypeError("Invalid Inline message action")
    }
    this.context = { ...context, actionId: context.actionId.trim() }
  }

  input(context: InvokeMessageActionContext) {
    const payload: InvokeMessageActionInput = {
      peerId: context.peerId,
      messageId: protocolId(context.messageId),
      actionId: context.actionId,
    }
    const input: RpcCall["input"] = {
      oneofKind: "invokeMessageAction",
      invokeMessageAction: payload,
    }
    return input
  }

  apply(result: RpcResult["result"] | undefined, _db: Db) {
    if (!result || result.oneofKind !== "invokeMessageAction") {
      throw new Error("invalid")
    }
  }
}

export const invokeMessageAction = (context: InvokeMessageActionContext) =>
  new InvokeMessageActionTransaction(context)
