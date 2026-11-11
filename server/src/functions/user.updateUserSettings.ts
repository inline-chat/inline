import { UserSettingsModel } from "@in/server/db/models/userSettings"
import { publishCacheInvalidation } from "@in/server/modules/cache/cluster"
import type { FunctionContext } from "@in/server/functions/_types"
import type { UserSettingsGeneralInput } from "@in/server/db/models/userSettings/types"
import type { Update } from "@inline-chat/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { db } from "@in/server/db"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { sendTransientUpdateFor } from "@in/server/modules/updates/sendUpdate"
import { Log } from "@in/server/utils/log"

const log = new Log("functions.updateUserSettings")

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
      { tx, senderUserId: context.currentUserId, excludeSessionId: context.currentSessionId },
    )

    return { settings, queued }
  })

  if (!mutation) {
    return { updates: [] }
  }

  // Invalidate only after the write and its durable projection commit.
  publishCacheInvalidation({ kind: "userSettings", userId: context.currentUserId })
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

  if (generalInput.privacy?.focusStatus) {
    await republishFocusStatus(context.currentUserId)
  }

  return {
    updates: [update],
  }
}

/** A Focus rule change re-sends every DM partner their view, so newly hidden viewers are cleared. */
const republishFocusStatus = async (userId: number): Promise<void> => {
  const [owner] = await db
    .select({
      online: users.online,
      lastOnline: users.lastOnline,
      focused: users.focused,
      focusUpdatedAt: users.focusUpdatedAt,
    })
    .from(users)
    .where(eq(users.id, userId))
    .limit(1)
  if (!owner) return
  await sendTransientUpdateFor({
    reason: { userPresenceUpdate: { userId, online: owner.online, lastOnline: owner.lastOnline, focus: owner } },
  }).catch((error: unknown) => {
    log.warn("Could not republish Focus status after a rule change", { userId, error })
  })
}
