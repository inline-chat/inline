import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { UpdatesModel } from "@in/server/db/models/updates"
import { updates, UpdateBucket } from "@in/server/db/schema"
import { sql } from "drizzle-orm"
import type { ServerUpdate } from "@in/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

type EnqueueUserUpdateInput = {
  userId: number
  update: ServerUpdate["update"]
}

export const UserBucketUpdates = {
  async enqueue(input: EnqueueUserUpdateInput, options?: { tx?: Transaction }) {
    if (options?.tx) {
      await insertUserUpdate(options.tx, input)
      return
    }

    await db.transaction(async (tx) => {
      await insertUserUpdate(tx, input)
    })
  },
}

const selectLatestSeq = async (tx: Transaction, userId: number): Promise<number> => {
  const [result] = await tx.execute<{ seq: number }>(
    sql`
      SELECT ${updates.seq} AS seq
      FROM ${updates}
      WHERE ${updates.bucket} = ${UpdateBucket.User}
        AND ${updates.entityId} = ${userId}
      ORDER BY ${updates.seq} DESC
      LIMIT 1
      FOR UPDATE
    `,
  )

  return result?.seq ?? 0
}

const insertUserUpdate = async (tx: Transaction, input: EnqueueUserUpdateInput) => {
  const currentSeq = await selectLatestSeq(tx, input.userId)
  const nextSeq = currentSeq + 1
  const now = new Date()

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
}

