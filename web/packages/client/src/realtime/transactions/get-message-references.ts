import type {
  GetMessagesInput,
  InputPeer,
  RpcCall,
  RpcResult,
} from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import type { MessageID } from "@inline/ids"
import type { Db } from "../../database"
import { toBigInt } from "./helpers"
import { messageModel } from "./mappers"
import { Query, type Transaction } from "./transaction"

export type GetMessageReferencesContext = {
  peerId: InputPeer
  messageIds: MessageID[]
}

/**
 * Exact message lookup for embedded replies. Results are persisted for
 * offline use but deliberately do not join the resident history window.
 */
export class GetMessageReferencesTransaction
  implements Transaction<GetMessageReferencesContext>
{
  readonly method = Method.GET_MESSAGES
  readonly kind = Query()
  readonly context: GetMessageReferencesContext

  constructor(context: GetMessageReferencesContext) {
    this.context = context
  }

  input(context: GetMessageReferencesContext) {
    const payload: GetMessagesInput = {
      peerId: context.peerId,
      messageIds: context.messageIds.map((id) => toBigInt(id)!),
    }
    const input: RpcCall["input"] = {
      oneofKind: "getMessages",
      getMessages: payload,
    }
    return input
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getMessages") {
      throw new Error("invalid")
    }
    for (const message of result.getMessages.messages) {
      db.storeNonResidentObject(messageModel(message))
    }
  }
}

export const getMessageReferences = (
  context: GetMessageReferencesContext,
) => new GetMessageReferencesTransaction(context)
