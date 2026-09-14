import type {
  ReserveChatIdsInput,
  RpcCall,
  RpcResult,
} from "@inline-chat/protocol/core"
import { Method } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { Mutation, type Transaction } from "./transaction"

export type ReserveChatIdsContext = {
  count: number
}

/**
 * A transient allocation RPC. Losing its result only strands server-side IDs
 * until expiry; replaying it would allocate more IDs, so it is never retried.
 */
export class ReserveChatIdsTransaction
  implements Transaction<ReserveChatIdsContext>
{
  readonly method = Method.RESERVE_CHAT_IDS
  readonly kind = Mutation({ transient: true })
  readonly context: ReserveChatIdsContext

  constructor(context: ReserveChatIdsContext) {
    if (!Number.isInteger(context.count) || context.count < 1 || context.count > 10) {
      throw new RangeError("Reserved chat ID count must be between 1 and 10")
    }
    this.context = context
  }

  input(context: ReserveChatIdsContext) {
    const payload: ReserveChatIdsInput = { count: context.count }
    const input: RpcCall["input"] = {
      oneofKind: "reserveChatIds",
      reserveChatIds: payload,
    }
    return input
  }

  apply(result: RpcResult["result"] | undefined, _db: Db) {
    if (
      !result ||
      result.oneofKind !== "reserveChatIds" ||
      result.reserveChatIds.reservations.length === 0
    ) {
      throw new Error("invalid")
    }
  }
}

export const reserveChatIds = (count: number) =>
  new ReserveChatIdsTransaction({ count })
