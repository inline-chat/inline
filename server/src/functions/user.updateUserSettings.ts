import { UserSettingsModel } from "@in/server/db/models/userSettings"
import { invalidateUserSettingsCache } from "@in/server/modules/cache/userSettings"
import type { FunctionContext } from "@in/server/functions/_types"
import type { UserSettingsGeneralInput } from "@in/server/db/models/userSettings/types"
import type { Update } from "@inline-chat/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { db } from "@in/server/db"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

export interface UpdateUserSettingsInput {
  general?: UserSettingsGeneralInput
}

export interface UpdateUserSettingsResult {
  updates: Update[]
}

export const updateUserSettings = async (
  input: UpdateUserSettingsInput,
  context: FunctionContext,
): Promise<UpdateUserSettingsResult> => {
  if (!input.general) {
    return {
      updates: [],
    }
  }
  const generalInput = input.general

  const mutation = await db.transaction(async (tx) => {
    // Merge and persist under the user's row lock. The durable user-bucket
    // projection is enqueued before releasing that same owner, so its seq and
    // payload cannot be reordered relative to a concurrent settings update.
    const result = await UserSettingsModel.updateGeneralWithPatch(context.currentUserId, generalInput, { tx })
    if (!result.changed) {
      return undefined
    }

    const settings = Encoders.userSettings({ general: result.general })
    const queued = await UserBucketUpdates.enqueue(
      {
        userId: context.currentUserId,
        update: {
          oneofKind: "userSettings",
          userSettings: { settings },
        },
      },
      { tx },
    )

    return { settings, queued }
  })

  if (!mutation) {
    return { updates: [] }
  }

  // Invalidate only after the write and its durable projection commit.
  invalidateUserSettingsCache(context.currentUserId)

  // Create update for user settings change
  const update: Update = {
    seq: mutation.queued.seq,
    date: encodeDateStrict(mutation.queued.date),
    update: {
      oneofKind: "updateUserSettings",
      updateUserSettings: {
        settings: mutation.settings,
      },
    },
  }

  // Push update to the current user in real-time
  RealtimeUpdates.pushToUser(context.currentUserId, [update], { skipSessionId: context.currentSessionId })

  return {
    updates: [update],
  }
}
