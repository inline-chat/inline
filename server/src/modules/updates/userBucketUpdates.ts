import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { UpdatesModel } from "@in/server/db/models/updates"
import { updates, UpdateBucket, users } from "@in/server/db/schema"
import { eq, sql } from "drizzle-orm"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"

type EnqueueUserUpdateInput = {
  userId: number
  update: ServerUpdate["update"]
}

export const UserBucketUpdates = {
  async enqueue(input: EnqueueUserUpdateInput, options?: { tx?: Transaction }): Promise<UpdateSeqAndDate> {
    if (options?.tx) {
      return await insertUserUpdate(options.tx, input)
    }

    return await db.transaction(async (tx) => {
      return await insertUserUpdate(tx, input)
    })
  },

  /**
   * Enqueue multiple user-bucket updates in a single transaction.
   * Sorts by `userId` to provide a consistent lock order and avoid deadlocks.
   */
  async enqueueMany(
    inputs: EnqueueUserUpdateInput[],
    options?: { tx?: Transaction },
  ): Promise<UpdateSeqAndDate[]> {
    if (inputs.length === 0) return []

    if (options?.tx) {
      return await insertUserUpdates(options.tx, inputs)
    }

    return await db.transaction(async (tx) => {
      return await insertUserUpdates(tx, inputs)
    })
  },
}

const allocateNextSeq = async (tx: Transaction, userId: number, now: Date): Promise<number> => {
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

  const [result] = await tx
    .update(users)
    .set({
      updateSeq: nextSeqExpr,
      lastUpdateDate: now,
    })
    .where(eq(users.id, userId))
    .returning({ seq: users.updateSeq })

  if (result?.seq === null || result?.seq === undefined) {
    throw new Error(`Failed to allocate user-bucket seq: ${userId}`)
  }

  return result.seq
}

const insertUserUpdate = async (tx: Transaction, input: EnqueueUserUpdateInput): Promise<UpdateSeqAndDate> => {
  const now = new Date()
  const nextSeq = await allocateNextSeq(tx, input.userId, now)

  const serverUpdate: ServerUpdate = {
    seq: nextSeq,
    date: encodeDateStrict(now),
    update: input.update,
  }

  const updateRecord = UpdatesModel.build(serverUpdate)

  await tx.insert(updates).values({
    bucket: UpdateBucket.User,
    entityId: input.userId,
    seq: nextSeq,
    payload: updateRecord.encrypted,
    date: now,
  })

  return { seq: nextSeq, date: now }
}

const insertUserUpdates = async (tx: Transaction, inputs: EnqueueUserUpdateInput[]): Promise<UpdateSeqAndDate[]> => {
  const indexed = inputs.map((input, index) => ({ input, index }))
  // Deterministic ordering:
  // - Sort by userId to avoid deadlocks when multiple users are updated in one tx
  // - Tie-break by original index so updates for the same user keep their caller order
  indexed.sort((a, b) => a.input.userId - b.input.userId || a.index - b.index)

  const results: UpdateSeqAndDate[] = new Array(inputs.length)

  for (const { input, index } of indexed) {
    results[index] = await insertUserUpdate(tx, input)
  }

  return results
}
