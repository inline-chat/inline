import { ServerUpdate } from "@in/protocol/server"
import { UpdateBucket, updates, type DbUpdate } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import { encryptBinary } from "@in/server/modules/encryption/encryption"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

export const UpdatesModel = {
  build: buildServerUpdate,
  decrypt: decryptUpdate,
  insertUpdate,
}

export type DecryptedUpdate = Omit<DbUpdate, "payload"> & {
  payload: ServerUpdate
}

function decryptUpdate(dbUpdate: DbUpdate): DecryptedUpdate {
  const { payload: encrypted, ...rest } = dbUpdate
  const binary = Encryption2.decryptBinary(encrypted)
  const payload = ServerUpdate.fromBinary(binary)
  return { ...rest, payload }
}

export type UpdateBoxInput =
  | {
      type: UpdateBucket.Chat
      chatId: number
    }
  | {
      type: UpdateBucket.User
      userId: number
    }
  | {
      type: UpdateBucket.Space
      spaceId: number
    }

function buildServerUpdate(update: ServerUpdate) {
  let binary = ServerUpdate.toBinary(update)
  let encrypted = Encryption2.encrypt(binary)

  return { encrypted }
}

/** Chat or Space */
interface InsertUpdateInputEntity {
  id: number
  updateSeq: number | null | undefined
}
type InsertUpdateInput = {
  update: ServerUpdate["update"]
  bucket: UpdateBucket
  entity: InsertUpdateInputEntity
}
type InsertUpdateOutput = UpdateSeqAndDate
export type UpdateSeqAndDate = {
  seq: number
  date: Date
}

async function insertUpdate(tx: Transaction, input: InsertUpdateInput): Promise<InsertUpdateOutput> {
  const { update, entity, bucket } = input

  const seq = (entity.updateSeq ?? 0) + 1
  const date = new Date()

  const updateRecord = UpdatesModel.build({
    update: update,
    seq: seq,
    date: encodeDateStrict(date),
  })

  await tx.insert(updates).values({
    bucket: bucket,
    entityId: entity.id,
    seq: seq,
    payload: updateRecord.encrypted,
    date: date,
  })

  return { seq, date }
}
