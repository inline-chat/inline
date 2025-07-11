import { db } from "@in/server/db"
import { members, type DbMemberRole } from "@in/server/db/schema"
import { MemberNotExistsError } from "@in/server/modules/effect/commonErrors"
import { and, eq } from "drizzle-orm"
import { Effect } from "effect"

/**
 * Delete a member from a space (Effect)
 * @param spaceId - The id of the space
 * @param userId - The id of the user to delete
 * @returns True if member was deleted, false if they weren't a member
 */
export const deleteMemberEffect = (spaceId: number, userId: number) => {
  return Effect.gen(function* () {
    const member = yield* Effect.tryPromise(() =>
      db
        .delete(members)
        .where(and(eq(members.spaceId, spaceId), eq(members.userId, userId)))
        .returning(),
    ).pipe(Effect.catchAll(() => Effect.fail(new MemberNotExistsError())))

    if (member.length === 0) {
      return yield* Effect.fail(new MemberNotExistsError())
    }

    return yield* Effect.succeed(true)
  })
}
