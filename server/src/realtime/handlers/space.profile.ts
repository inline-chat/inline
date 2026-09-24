import { db } from "@in/server/db"
import { members, spaces } from "@in/server/db/schema"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { requireOwnedSpacePhoto } from "@in/server/modules/spaces/spacePhoto"
import { publishDurableReference } from "@in/server/modules/internalMessaging/durable"
import { encodeSpace } from "@in/server/realtime/encoders/encodeSpace"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import type { HandlerContext } from "@in/server/realtime/types"
import type { SetSpacePhotoInput, SetSpacePhotoResult, Update, UpdateSpaceProfile } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"

const log = new Log("space.profile")

export async function setSpacePhotoHandler(input: SetSpacePhotoInput, context: HandlerContext): Promise<SetSpacePhotoResult> {
  const spaceId = Number(input.spaceId)
  if (!Number.isSafeInteger(spaceId) || spaceId <= 0) throw RealtimeRpcError.SpaceIdInvalid()
  const photoFileUniqueId = await requireOwnedSpacePhoto(input.fileUniqueId, context.userId)
  const { space, update } = await db.transaction(async (tx) => {
    const [existing] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)
    if (!existing || existing.deleted !== null) throw RealtimeRpcError.SpaceIdInvalid()
    const [member] = await tx.select().from(members).where(and(
      eq(members.spaceId, spaceId), eq(members.userId, context.userId),
    )).for("update").limit(1)
    if (!member || (member.role !== "owner" && member.role !== "admin")) throw RealtimeRpcError.SpaceAdminRequired()
    const profile: UpdateSpaceProfile = { spaceId: input.spaceId, photoFileUniqueId: photoFileUniqueId ?? undefined, isPro: existing.isPro }
    const update = await UpdatesModel.insertUpdate(tx, {
      update: { oneofKind: "spaceProfile", spaceProfile: profile },
      bucket: UpdateBucket.Space, entity: existing,
    })
    const [space] = await tx.update(spaces).set({ photoFileUniqueId, updateSeq: update.seq, lastUpdateDate: update.date })
      .where(eq(spaces.id, spaceId)).returning()
    if (!space) throw RealtimeRpcError.SpaceIdInvalid()
    return { space, update }
  })
  const encoded = encodeSpace(space, { encodingForUserId: context.userId })
  const live: Update = {
    seq: update.seq, date: encodeDateStrict(update.date),
    update: { oneofKind: "spaceProfile", spaceProfile: {
      spaceId: input.spaceId, photoFileUniqueId: encoded.photoFileUniqueId,
      photoUrl: encoded.photoUrl, isPro: encoded.isPro ?? false,
    } },
  }
  // Publish only after commit. Remote peers fetch the durable space bucket;
  // local delivery rechecks membership and joins its bounded fanout.
  publishDurableReference({ bucket: { kind: "space", spaceId }, frontier: update.seq })
  try {
    await RealtimeUpdates.pushToSpace(spaceId, [live])
  } catch (error) {
    // The mutation is already durable. A local transport failure must not
    // report the edit as failed; bucket replay remains its recovery path.
    log.warn("Space profile delivery failed after commit", { spaceId, error })
  }
  return { space: encoded, updates: [live] }
}
