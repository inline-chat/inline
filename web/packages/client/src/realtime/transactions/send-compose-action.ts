import {
  Method,
  UpdateComposeAction_ComposeAction,
  type InputPeer,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { Mutation, type Transaction } from "./transaction"

export type SendComposeActionContext = {
  peerId: InputPeer
  /** Absent: the action stopped. */
  action?: UpdateComposeAction_ComposeAction
}

/**
 * `SEND_COMPOSE_ACTION`: ephemeral. Needs a connection (`transient`), sent
 * once, never stored; the next refresh replaces a lost one.
 */
export class SendComposeActionTransaction implements Transaction<SendComposeActionContext> {
  readonly method = Method.SEND_COMPOSE_ACTION
  readonly kind = Mutation({ transient: true })

  constructor(readonly context: SendComposeActionContext) {}

  input(context: SendComposeActionContext): RpcCall["input"] {
    return {
      oneofKind: "sendComposeAction",
      sendComposeAction: {
        peerId: context.peerId,
        ...(context.action != null && context.action !== UpdateComposeAction_ComposeAction.NONE
          ? { action: context.action }
          : {}),
      },
    }
  }

  apply(result: RpcResult["result"] | undefined, _db: Db) {
    if (result && result.oneofKind !== "sendComposeAction") throw new Error("invalid")
  }
}

export const sendComposeAction = (context: SendComposeActionContext) => new SendComposeActionTransaction(context)
