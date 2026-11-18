import { Method, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { SpaceID } from "@inline/ids"
import type { Db } from "../../database"
import { reconcileSpaceMember } from "../updates/membership"
import { applySpaceSettings } from "../updates/settings"
import { upsertSpace } from "./mappers"
import { Query, type Transaction } from "./transaction"

export type GetSpaceContext = { spaceId: SpaceID }

/**
 * `GET_SPACE`: one space with the account's own membership and the space
 * settings (never the roster; that is `GET_SPACE_MEMBERS`).
 */
export class GetSpaceTransaction implements Transaction<GetSpaceContext> {
  readonly method = Method.GET_SPACE
  readonly kind = Query()

  constructor(readonly context: GetSpaceContext) {}

  input(context: GetSpaceContext): RpcCall["input"] {
    return { oneofKind: "getSpace", getSpace: { spaceId: BigInt(context.spaceId) } }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "getSpace") throw new Error("invalid")
    const { space, membership, settings } = result.getSpace
    if (!space || String(space.id) !== String(this.context.spaceId)) {
      throw new Error("invalid")
    }
    db.batch(() => {
      upsertSpace(db, space)
      if (membership && String(membership.spaceId) === String(space.id)) {
        reconcileSpaceMember(db, membership)
      }
      if (settings) applySpaceSettings(db, { ...settings, spaceId: space.id })
    })
  }
}

export const getSpace = (context: GetSpaceContext) => new GetSpaceTransaction(context)
