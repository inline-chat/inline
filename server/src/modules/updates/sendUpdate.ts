/**
 * Send Update
 *
 * - goal for this module is to make it easy for methods and other modules to send updates to relevant subscribers without leaking the logic for finding those inside the other modules
 * - Transient updates are updates that are not persisted to the database and are only sent to the relevant subscribers
 * - Persistent updates are updates that are persisted to the database and are kept in the database for all subscribers to get by some PTS
 */

import { DialogsModel } from "@in/server/db/models/dialogs"
import { type TPeerInfo, type TUpdateComposeAction } from "@in/server/api-types"
import { Log, LogLevel } from "@in/server/utils/log"
import { type FocusStatus, Update, UpdateComposeAction_ComposeAction, UserStatus_Status } from "@inline-chat/protocol/core"
import { encodeFocusForViewer, focusViewersAllowed, type FocusState } from "@in/server/modules/privacy/focusStatus"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { getUpdateGroup } from "@in/server/modules/updates"
import { encodeDate } from "@in/server/realtime/encoders/helpers"
import * as transientRealtime from "@in/server/modules/internalMessaging/transient"

const log = new Log("Updates.sendUpdate", LogLevel.INFO)
const MAX_CONCURRENT_TRANSIENT_RECIPIENTS = 32

export type SendUpdateTransientReason =
  | {
      userPresenceUpdate: {
        userId: number
        online: boolean
        lastOnline: Date | null
        /** Include each recipient's view of this Focus state; omitted, clients keep theirs. */
        focus?: FocusState
        /** Send only to recipients the owner's Focus rule allows. */
        focusAudienceOnly?: boolean
      }
    }
  | {
      composeAction: { update: TUpdateComposeAction; target: TPeerInfo; otherPeerId: TPeerInfo }
    }

/** Sends an array of updates to a group of users tailored based on the reason, context, and user id */
export const sendTransientUpdateFor = async ({ reason }: { reason: SendUpdateTransientReason }) => {
  if ("userPresenceUpdate" in reason) {
    const { userId, online, lastOnline, focus, focusAudienceOnly } = reason.userPresenceUpdate
    // 90/10 solution to get all users with private dialogs with the current user then send updates via connection manager to those users
    let userIds = await DialogsModel.getUserIdsWeHavePrivateDialogsWith({ userId })
    const focusAllowed = focus ? await focusViewersAllowed(userId, userIds) : undefined
    if (focusAllowed && focusAudienceOnly) userIds = userIds.filter((id) => focusAllowed.has(id))
    log.debug(`Sending user presence update to ${userIds.length} users`)
    const now = Date.now()
    const focusFor = (targetUserId: number): FocusStatus | undefined =>
      focus && focusAllowed ? encodeFocusForViewer(focus, focusAllowed.has(targetUserId), now) : undefined
    for (let offset = 0; offset < userIds.length; offset += MAX_CONCURRENT_TRANSIENT_RECIPIENTS) {
      const recipients = userIds.slice(offset, offset + MAX_CONCURRENT_TRANSIENT_RECIPIENTS)
      await Promise.all(recipients.map(async (targetUserId) => {
        const targetFocus = focusFor(targetUserId)
        await RealtimeUpdates.pushToUser(targetUserId, [
          getNewUpdatesForUserPresenceUpdate(userId, online, lastOnline, targetFocus),
        ])
        transientRealtime.publishUserPresence(targetUserId, userId, online, lastOnline, targetFocus)
      }))
    }
    return
  }

  if ("composeAction" in reason) {
    const { update, target, otherPeerId } = reason.composeAction
    const newUpdates = getNewUpdatesForComposeAction(update.userId, target, otherPeerId, update)

    if ("userId" in target) {
      RealtimeUpdates.pushToUser(target.userId, [newUpdates])
    } else {
      const group = await getUpdateGroup(target, { currentUserId: update.userId })
      for (const userId of group.userIds) {
        if (userId !== update.userId) {
          RealtimeUpdates.pushToUser(userId, [newUpdates])
        }
      }
    }
    return
  }

  throw new Error("Invalid reason")
}

const getNewUpdatesForComposeAction = (
  userId: number,
  peerId: TPeerInfo,
  otherPeerId: TPeerInfo,
  action: TUpdateComposeAction,
) => {
  const currentUserId = userId
  // New update
  let newAction: UpdateComposeAction_ComposeAction = UpdateComposeAction_ComposeAction.NONE
  if (action.action === "typing") {
    newAction = UpdateComposeAction_ComposeAction.TYPING
  } else if (action.action === "uploadingDocument") {
    newAction = UpdateComposeAction_ComposeAction.UPLOADING_DOCUMENT
  } else if (action.action === "uploadingPhoto") {
    newAction = UpdateComposeAction_ComposeAction.UPLOADING_PHOTO
  } else if (action.action === "uploadingVideo") {
    newAction = UpdateComposeAction_ComposeAction.UPLOADING_VIDEO
  } else if (action.action === "working") {
    newAction = UpdateComposeAction_ComposeAction.WORKING
  } else if (action.action === "recordingVoice") {
    newAction = UpdateComposeAction_ComposeAction.RECORDING_VOICE
  }

  const updateComposeAction: Update = {
    update: {
      oneofKind: "updateComposeAction",
      updateComposeAction: {
        userId: BigInt(currentUserId),
        peerId: Encoders.peer(otherPeerId),
        action: newAction,
      },
    },
  }

  return updateComposeAction
}

export const getNewUpdatesForUserPresenceUpdate = (
  userId: number,
  online: boolean,
  lastOnline: Date | null,
  focus?: FocusStatus,
): Update => {
  return {
    update: {
      oneofKind: "updateUserStatus",
      updateUserStatus: {
        userId: BigInt(userId),
        status: {
          online: online ? UserStatus_Status.ONLINE : UserStatus_Status.OFFLINE,
          lastOnline: {
            date: lastOnline ? encodeDate(lastOnline) : undefined,
          },
          focus,
        },
      },
    },
  }
}
