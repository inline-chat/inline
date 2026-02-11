import { GetMeInput, Method, type RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { Query } from "./transaction"
import type { Transaction } from "./transaction"
import { upsertUser } from "./mappers"

export type GetMeContext = {}

export class GetMeTransaction implements Transaction<GetMeContext> {
  readonly method = Method.GET_ME
  readonly kind = Query()
  readonly context: GetMeContext = {}

  input(_context: GetMeContext): { oneofKind: "getMe"; getMe: GetMeInput } {
    return { oneofKind: "getMe", getMe: GetMeInput.create() }
  }

  async apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getMe") {
      throw new Error("invalid")
    }
    if (result.getMe.user) {
      upsertUser(db, result.getMe.user)
    }
  }
}

export const getMe = () => new GetMeTransaction()
