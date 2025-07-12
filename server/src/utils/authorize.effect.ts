import { db } from "@in/server/db"
import { and, eq, inArray } from "drizzle-orm"
import { members, spaces, type DbMember, chatParticipants, integrations } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Data, Effect } from "effect"

export class UserNotMemberError extends Data.TaggedError("authorize/UserNotMember")<{}> {}
export class UserNotAdminError extends Data.TaggedError("authorize/UserNotAdmin")<{}> {}

const spaceAdmin = (spaceId: number, currentUserId: number) => {
  return Effect.gen(function* () {
    const member = yield* Effect.tryPromise(() =>
      db.query.members.findFirst({
        where: {
          spaceId,
          userId: currentUserId,
          OR: [{ role: "admin" }, { role: "owner" }],
        },
      }),
    ).pipe(Effect.catchAll(() => Effect.fail(new UserNotMemberError())))

    if (!member) {
      return yield* Effect.fail(new UserNotAdminError())
    }

    return yield* Effect.succeed({ member })
  })
}

export const AuthorizeEffect = {
  spaceAdmin,
}
