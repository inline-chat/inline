import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { UpdatesModel } from "@in/server/db/models/updates"
import { updates, UpdateBucket, users } from "@in/server/db/schema"
import { eq, sql } from "drizzle-orm"
import type { ServerUpdate } from "@in/server/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { acquireUpdateDiscoveryWriterFence } from "@in/server/modules/updates/updateDiscoveryBarrier"
import { publishDurableReference } from "@in/server/modules/internalMessaging/durable"
import { registerPostCommitHook, type PostCommitHook } from "@in/server/db/commitHooks"

type EnqueueUserUpdateInput = {
  userId: number
  update: ServerUpdate["update"]
}

type EnqueueUserUpdateOptions = {
  tx?: Transaction
  senderUserId?: number
  excludeSessionId?: number
}

class UserFrontierPublication implements PostCommitHook {
  constructor(
    private readonly userId: number,
    private frontier: number,
    private senderUserId?: number,
    private excludeSessionId?: number,
  ) {}

  async run() {
    publishDurableReference({
      bucket: { kind: "user", userId: this.userId },
      frontier: this.frontier,
      ...(this.senderUserId === undefined ? {} : { senderUserId: this.senderUserId }),
      ...(this.excludeSessionId === undefined ? {} : { excludeSessionId: this.excludeSessionId }),
    })
  }

  merge(next: PostCommitHook) {
    if (!(next instanceof UserFrontierPublication) || next.userId !== this.userId) {
      throw new Error("User frontier publication merged with an incompatible post-commit hook")
    }
    this.frontier = Math.max(this.frontier, next.frontier)
    // A frontier covers every earlier update in its coalesced group. Excluding
    // session B for the latest update would make B miss an earlier update from
    // session A, so preserve the skip only when every update had the same
    // exact sender/session pair.
    if (this.senderUserId !== next.senderUserId || this.excludeSessionId !== next.excludeSessionId) {
      this.senderUserId = undefined
      this.excludeSessionId = undefined
    }
  }
}

const registerUserFrontierPublication = (
  tx: Transaction,
  userId: number,
  frontier: number,
  options?: EnqueueUserUpdateOptions,
) => {
  registerPostCommitHook(
    tx,
    `user-frontier:${userId}`,
    new UserFrontierPublication(userId, frontier, options?.senderUserId, options?.excludeSessionId),
  )
}

export const UserBucketUpdates = {
  async enqueue(input: EnqueueUserUpdateInput, options?: EnqueueUserUpdateOptions): Promise<UpdateSeqAndDate> {
    if (options?.tx) {
      return await insertUserUpdate(options.tx, input, options)
    }

    return await db.transaction(async (tx) => {
      return await insertUserUpdate(tx, input, options)
    })
  },

  /**
   * Enqueue multiple user-bucket updates in a single transaction.
   * Sorts by `userId` to provide a consistent lock order and avoid deadlocks.
   */
  async enqueueMany(
    inputs: EnqueueUserUpdateInput[],
    options?: EnqueueUserUpdateOptions,
  ): Promise<UpdateSeqAndDate[]> {
    if (inputs.length === 0) return []

    if (options?.tx) {
      return await insertUserUpdates(options.tx, inputs, options)
    }

    return await db.transaction(async (tx) => {
      return await insertUserUpdates(tx, inputs, options)
    })
  },
}

const allocateNextSeq = async (tx: Transaction, userId: number): Promise<UpdateSeqAndDate> => {
  // Acquire the shared fence before allocating either the sequence or its
  // database-clock timestamp. It remains held until the outer tx commits.
  const databaseDate = await acquireUpdateDiscoveryWriterFence(tx)
  // Use the query builder so Postgres doesn't see a qualified SET target like `"users"."update_seq"`,
  // which is invalid syntax in UPDATE SET lists.
  // BAND-AID: We defensively reconcile against the latest persisted user-bucket seq in `updates`.
  // `users.update_seq` should be the source of truth, but if it drifts behind in production data,
  // trusting it alone can re-emit an already used seq and hit `updates_unique`.
  const nextSeqExpr = sql<number>`
    GREATEST(
      COALESCE(${users.updateSeq}, 0),
      COALESCE(
        (
          SELECT ${updates.seq}
          FROM ${updates}
          WHERE ${updates.bucket} = ${UpdateBucket.User}
            AND ${updates.entityId} = ${userId}
          ORDER BY ${updates.seq} DESC
          LIMIT 1
        ),
        0
      )
    ) + 1
  `
  // The application clock used to be sampled before this UPDATE acquired the
  // user-row lock. The fenced database sample establishes commit discovery;
  // GREATEST with the persisted row keeps dates monotonic across allocators.
  const nextDateExpr = sql<Date>`
    GREATEST(
      COALESCE(${users.lastUpdateDate}, '-infinity'::timestamp),
      ${databaseDate.toISOString()}::timestamp
    )
  `
  const [result] = await tx
    .update(users)
    .set({
      updateSeq: nextSeqExpr,
      lastUpdateDate: nextDateExpr,
    })
    .where(eq(users.id, userId))
    .returning({ seq: users.updateSeq, date: users.lastUpdateDate })

  if (result?.seq === null || result?.seq === undefined || !result.date) {
    throw new Error(`Failed to allocate user-bucket seq: ${userId}`)
  }

  return { seq: result.seq, date: result.date }
}

const insertUserUpdate = async (
  tx: Transaction,
  input: EnqueueUserUpdateInput,
  options?: EnqueueUserUpdateOptions,
): Promise<UpdateSeqAndDate> => {
  const { seq: nextSeq, date } = await allocateNextSeq(tx, input.userId)

  const serverUpdate: ServerUpdate = {
    seq: nextSeq,
    date: encodeDateStrict(date),
    update: input.update,
  }

  const updateRecord = UpdatesModel.build(serverUpdate)

  await tx.insert(updates).values({
    bucket: UpdateBucket.User,
    entityId: input.userId,
    seq: nextSeq,
    payload: updateRecord.encrypted,
    date,
  })
  registerUserFrontierPublication(tx, input.userId, nextSeq, options)

  return { seq: nextSeq, date }
}

const insertUserUpdates = async (
  tx: Transaction,
  inputs: EnqueueUserUpdateInput[],
  options?: EnqueueUserUpdateOptions,
): Promise<UpdateSeqAndDate[]> => {
  const indexed = inputs.map((input, index) => ({ input, index }))
  // Deterministic ordering:
  // - Sort by userId to avoid deadlocks when multiple users are updated in one tx
  // - Tie-break by original index so updates for the same user keep their caller order
  indexed.sort((a, b) => a.input.userId - b.input.userId || a.index - b.index)

  const results: UpdateSeqAndDate[] = new Array(inputs.length)

  for (const { input, index } of indexed) {
    results[index] = await insertUserUpdate(tx, input, options)
  }

  return results
}
