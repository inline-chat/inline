import { UpdatesModel } from "@in/server/db/models/updates"
import { files, spaces, users } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import { publishDurableReference } from "@in/server/modules/internalMessaging/durable"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeSpace } from "@in/server/realtime/encoders/encodeSpace"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import type { Update } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"
import type { Subject } from "./entitlements"

const log = new Log("billing.notify")

/** Delivers an already-durable update after commit. */
export type ProPush = () => Promise<void>

/**
 * Records the subject's new `is_pro` as a durable update inside the caller's
 * transaction (space bucket for spaces, the user's own bucket for users) and
 * returns the live push to run after commit.
 */
export const enqueueProUpdate = async (tx: Transaction, subject: Subject): Promise<ProPush | null> => {
  if (subject.userId !== undefined) {
    const userId = subject.userId
    const [user] = await tx.select().from(users).where(eq(users.id, userId)).limit(1)
    if (!user) return null
    const photoFile = user.photoFileId
      ? (await tx.select().from(files).where(eq(files.id, user.photoFileId)).limit(1))[0]
      : undefined
    const protocolUser = encodeUser({ user, photoFile, viewerUserId: userId })
    const seqDate = await UserBucketUpdates.enqueue(
      { userId, update: { oneofKind: "updatedUser", updatedUser: { user: protocolUser } } },
      { tx },
    )
    const live: Update = {
      seq: seqDate.seq,
      date: encodeDateStrict(seqDate.date),
      update: { oneofKind: "updatedUser", updatedUser: { user: protocolUser } },
    }
    return async () => {
      RealtimeUpdates.pushToUser(userId, [live])
    }
  }

  const spaceId = subject.spaceId!
  const [existing] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)
  if (!existing || existing.deleted !== null) return null
  const encoded = encodeSpace(existing, { encodingForUserId: existing.creatorId ?? 0 })
  const profile = {
    spaceId: BigInt(spaceId),
    photoFileUniqueId: existing.photoFileUniqueId ?? undefined,
    isPro: existing.isPro,
  }
  const update = await UpdatesModel.insertUpdate(tx, {
    update: { oneofKind: "spaceProfile", spaceProfile: profile },
    bucket: UpdateBucket.Space,
    entity: existing,
  })
  await tx.update(spaces).set({ updateSeq: update.seq, lastUpdateDate: update.date }).where(eq(spaces.id, spaceId))
  const live: Update = {
    seq: update.seq,
    date: encodeDateStrict(update.date),
    update: { oneofKind: "spaceProfile", spaceProfile: { ...profile, photoUrl: encoded.photoUrl } },
  }
  return async () => {
    publishDurableReference({ bucket: { kind: "space", spaceId }, frontier: update.seq })
    await RealtimeUpdates.pushToSpace(spaceId, [live])
  }
}

/** Runs post-commit pushes; a delivery failure leaves bucket replay as recovery. */
export const runProPushes = async (pushes: readonly ProPush[]) => {
  for (const push of pushes) {
    try {
      await push()
    } catch (error) {
      log.warn("billing Pro delivery failed after commit", { error })
    }
  }
}
