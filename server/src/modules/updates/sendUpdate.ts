/**
 * Send Update
 *
 * - goal for this module is to make it easy for methods and other modules to send updates to relevant subscribers without leaking the logic for finding those inside the other modules
 * - Transient updates are updates that are not persisted to the database and are only sent to the relevant subscribers
 * - Persistent updates are updates that are persisted to the database and are kept in the database for all subscribers to get by some PTS
 */

import { DialogsModel } from "@in/server/db/models/dialogs"
import { TUpdateUserStatus, type TPeerInfo, type TUpdateComposeAction, type TUpdateInfo } from "@in/server/api-types"
import { ApiError, InlineError } from "@in/server/types/errors"
import { Log, LogLevel } from "@in/server/utils/log"
import { connectionManager } from "@in/server/ws/connections"
import { Value } from "@sinclair/typebox/value"
import { Update, UpdateComposeAction_ComposeAction, UserStatus_Status } from "@in/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"

const log = new Log("Updates.sendUpdate", LogLevel.INFO)

export type SendUpdateTransientReason =
  | {
      userPresenceUpdate: { userId: number; online: boolean; lastOnline: Date | null }
    }
  | {
      composeAction: { update: TUpdateComposeAction; target: TPeerInfo; otherPeerId: TPeerInfo }
    }

/** Sends an array of updates to a group of users tailored based on the reason, context, and user id */
export const sendTransientUpdateFor = async ({ reason }: { reason: SendUpdateTransientReason }) => {
  if ("userPresenceUpdate" in reason) {
    const { userId, online, lastOnline } = reason.userPresenceUpdate
    // 90/10 solution to get all users with private dialogs with the current user then send updates via connection manager to those users
    const userIds = await DialogsModel.getUserIdsWeHavePrivateDialogsWith({ userId })
    log.debug(`Sending user presence update to ${userIds.length} users`)
    for (const targetUserId of userIds) {
      // New Updates
      const newUpdates = getNewUpdatesForUserPresenceUpdate(userId, online, lastOnline)
      RealtimeUpdates.pushToUser(targetUserId, [newUpdates])
    }
    return
  }

  if ("composeAction" in reason) {
    const { update, target, otherPeerId } = reason.composeAction
    const updates = [{ updateComposeAction: update }]
    const newUpdates = getNewUpdatesForComposeAction(update.userId, target, otherPeerId, update)

    if ("userId" in target) {
      RealtimeUpdates.pushToUser(target.userId, [newUpdates])
    } else {
      // not supported for threads
      // throw new InlineError(ApiError.PEER_INVALID)
      return
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

const getNewUpdatesForUserPresenceUpdate = (userId: number, online: boolean, lastOnline: Date | null): Update => {
  return {
    update: {
      oneofKind: "updateUserStatus",
      updateUserStatus: {
        userId: BigInt(userId),
        status: {
          online: online ? UserStatus_Status.ONLINE : UserStatus_Status.OFFLINE,
          lastOnline: {
            date: lastOnline ? BigInt(lastOnline.getTime()) : undefined,
          },
        },
      },
    },
  }
}
