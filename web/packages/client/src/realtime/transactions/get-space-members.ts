import { Method, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { SpaceID } from "@inline/ids"
import type { Db } from "../../database"
import { applySpaceRoster } from "../updates/membership"
import { upsertUser } from "./mappers"
import { Query, type Transaction } from "./transaction"

export type GetSpaceMembersContext = { spaceId: SpaceID }

/**
 * `GET_SPACE_MEMBERS`: the space's whole roster, covering the space bucket
 * through the result's `seq`. It replaces the stored roster; member events
 * at or below that sequence are then already applied.
 */
export class GetSpaceMembersTransaction
  implements Transaction<GetSpaceMembersContext>
{
  readonly method = Method.GET_SPACE_MEMBERS
  readonly kind = Query()

  constructor(readonly context: GetSpaceMembersContext) {}

  input(context: GetSpaceMembersContext): RpcCall["input"] {
    return {
      oneofKind: "getSpaceMembers",
      getSpaceMembers: { spaceId: BigInt(context.spaceId) },
    }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getSpaceMembers") {
      throw new Error("invalid")
    }
    const { members, users, seq } = result.getSpaceMembers
    db.batch(() => {
      for (const user of users) upsertUser(db, user)
      applySpaceRoster(db, this.context.spaceId, members, seq)
    })
  }
}

export const getSpaceMembers = (context: GetSpaceMembersContext) =>
  new GetSpaceMembersTransaction(context)
