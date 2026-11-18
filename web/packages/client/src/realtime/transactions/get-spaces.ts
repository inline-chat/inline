import { Method, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { upsertSpace } from "./mappers"
import { Query, type Transaction } from "./transaction"

/** `GET_SPACES`: the account's spaces. */
export class GetSpacesTransaction implements Transaction<Record<string, never>> {
  readonly method = Method.GET_SPACES
  readonly kind = Query()
  readonly context: Record<string, never> = {}

  input(): RpcCall["input"] {
    return { oneofKind: "getSpaces", getSpaces: {} }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getSpaces") throw new Error("invalid")
    db.batch(() => {
      for (const space of result.getSpaces.spaces) upsertSpace(db, space)
    })
  }
}

export const getSpaces = () => new GetSpacesTransaction()
