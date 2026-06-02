import { db } from "@in/server/db"
import { and, eq, inArray } from "drizzle-orm"
import { members } from "@in/server/db/schema"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Data, Effect } from "effect"

export class UserNotMemberError extends Data.TaggedError("authorize/UserNotMember")<{}> {}
export class UserNotAdminError extends Data.TaggedError("authorize/UserNotAdmin")<{}> {}

const spaceAdmin = (spaceId: number, currentUserId: number) => {
  return Effect.gen(function* () {
    const member = yield* Effect.tryPromise(() =>
      db._query.members.findFirst({
        where: and(
          eq(members.spaceId, spaceId),
          eq(members.userId, currentUserId),
          inArray(members.role, ["admin", "owner"]),
        ),
      }),
    ).pipe(Effect.catchAll(() => Effect.fail(RealtimeRpcError.InternalError())))

    if (!member) {
      return yield* Effect.fail(RealtimeRpcError.SpaceAdminRequired())
    }

    return yield* Effect.succeed({ member })
  })
}

export const AuthorizeEffect = {
  spaceAdmin,
}
