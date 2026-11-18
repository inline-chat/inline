import {
  Method,
  type InputPeer,
  type MessageFormSubmission,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { protocolId, type ChatID, type MessageID } from "@inline/ids"
import type { Db } from "../../database"
import { Mutation, type Transaction } from "./transaction"

export type SubmitMessageFormContext = {
  chatId: ChatID
  messageId: MessageID
  peerId?: InputPeer
  /** The form's `form_id`; the server invokes the message action with this ID. */
  formId: string
  form: MessageFormSubmission
}

/**
 * Submit a `BlockForm`: `INVOKE_MESSAGE_ACTION` with `action_id = form_id`
 * and the values (the proto's `BlockForm` comment). Transient like every
 * message action: a bot interaction is not replay-safe.
 */
export class SubmitMessageFormTransaction implements Transaction<SubmitMessageFormContext> {
  readonly method = Method.INVOKE_MESSAGE_ACTION
  readonly kind = Mutation({ transient: true })
  readonly context: SubmitMessageFormContext

  constructor(context: SubmitMessageFormContext) {
    if (
      BigInt(context.chatId) <= 0n ||
      BigInt(context.messageId) <= 0n ||
      !context.formId.trim() ||
      context.formId.length > 256
    ) {
      throw new TypeError("Invalid Inline form submission")
    }
    this.context = context
  }

  input(context: SubmitMessageFormContext): RpcCall["input"] {
    return {
      oneofKind: "invokeMessageAction",
      invokeMessageAction: {
        peerId: context.peerId,
        messageId: protocolId(context.messageId),
        actionId: context.formId,
        form: context.form,
      },
    }
  }

  apply(result: RpcResult["result"] | undefined, _db: Db) {
    if (!result || result.oneofKind !== "invokeMessageAction") throw new Error("invalid")
  }
}

export const submitMessageForm = (context: SubmitMessageFormContext) =>
  new SubmitMessageFormTransaction(context)
