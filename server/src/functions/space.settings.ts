import type {
  GetSpaceSettingsInput,
  GetSpaceSettingsResult,
  SpaceSettings,
  ToggleSpaceGridInput,
  ToggleSpaceGridResult,
  Update,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { SpaceSettingsModel } from "@in/server/db/models/spaceSettings"
import { UpdatesModel } from "@in/server/db/models/updates"
import { spaces } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getUpdateGroupForSpace } from "@in/server/modules/updates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import type { ServerUpdate } from "@in/server/protocol/server"
import { Authorize } from "@in/server/utils/authorize"
import { eq } from "drizzle-orm"
import { notifyGridSpaceChanged } from "@in/server/modules/grid/realtime"
import { clearGridPresenceForSpace, lockGridMutations } from "@in/server/modules/grid/roomLifecycle"

export async function getSpaceSettings(
  input: GetSpaceSettingsInput,
  context: FunctionContext,
): Promise<GetSpaceSettingsResult> {
  const spaceId = toPositiveSpaceId(input.spaceId)
  await AccessGuards.ensureSpaceMember(spaceId, context.currentUserId)

  return {
    settings: await SpaceSettingsModel.get(spaceId),
  }
}

export async function toggleSpaceGrid(
  input: ToggleSpaceGridInput,
  context: FunctionContext,
): Promise<ToggleSpaceGridResult> {
  const spaceId = toPositiveSpaceId(input.spaceId)
  await Authorize.spaceAdmin(spaceId, context.currentUserId)

  const { settings, update } = await db.transaction(async (tx) => {
    await lockGridMutations(tx)
    const [space] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)
    if (!space) {
      throw RealtimeRpcError.SpaceIdInvalid()
    }

    const settings = await SpaceSettingsModel.updateGrid(spaceId, input.enabled, tx)
    if (!input.enabled) await clearGridPresenceForSpace(tx, spaceId)
    const payload: ServerUpdate["update"] = {
      oneofKind: "spaceSettings",
      spaceSettings: { settings },
    }
    const update = await UpdatesModel.insertUpdate(tx, {
      update: payload,
      bucket: UpdateBucket.Space,
      entity: space,
    })

    await tx
      .update(spaces)
      .set({
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(spaces.id, spaceId))

    return { settings, update }
  })

  const updates = await pushSpaceSettingsUpdate({
    spaceId,
    settings,
    currentUserId: context.currentUserId,
    seq: update.seq,
    date: update.date,
  })
  await notifyGridSpaceChanged(spaceId)
  return { settings, updates }
}

async function pushSpaceSettingsUpdate(input: {
  spaceId: number
  settings: SpaceSettings
  currentUserId: number
  seq: number
  date: Date
}): Promise<Update[]> {
  const update: Update = {
    seq: input.seq,
    date: encodeDateStrict(input.date),
    update: {
      oneofKind: "spaceSettings",
      spaceSettings: {
        spaceId: BigInt(input.spaceId),
        settings: input.settings,
      },
    },
  }

  const updateGroup = await getUpdateGroupForSpace(input.spaceId, { currentUserId: input.currentUserId })
  updateGroup.userIds.forEach((userId) => {
    RealtimeUpdates.pushToUser(userId, [update])
  })

  return [update]
}

function toPositiveSpaceId(id: bigint): number {
  const value = Number(id)
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }
  return value
}
