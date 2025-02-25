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
import { createMessage, ServerMessageKind } from "@in/server/ws/protocol"
import { Value } from "@sinclair/typebox/value"
import { Update, UpdateComposeAction_ComposeAction, UserStatus_Status } from "@in/server/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"

const log = new Log("Updates.sendUpdate", LogLevel.INFO)

export type SendUpdateTransientReason =
  | {
      userPresenceUpdate: { userId: number; online: boolean; lastOnline: Date | null }
    }
  | {
      composeAction: { update: TUpdateComposeAction; target: TPeerInfo }
    }

/** Sends an array of updates to a group of users tailored based on the reason, context, and user id */
export const sendTransientUpdateFor = async ({ reason }: { reason: SendUpdateTransientReason }) => {
  if ("userPresenceUpdate" in reason) {
    const { userId, online, lastOnline } = reason.userPresenceUpdate
    // 90/10 solution to get all users with private dialogs with the current user then send updates via connection manager to those users
    const userIds = await DialogsModel.getUserIdsWeHavePrivateDialogsWith({ userId })
    log.debug(`Sending user presence update to ${userIds.length} users`)
    for (const targetUserId of userIds) {
      // Generate updates for this user
      const updates = [
        {
          updateUserStatus: Value.Encode(TUpdateUserStatus, {
            userId,
            online,
            lastOnline: lastOnline ?? new Date(),
          }),
        },
      ]
      sendUpdatesToUser(targetUserId, updates)

      // New Updates
      const newUpdates = getNewUpdatesForUserPresenceUpdate(userId, online, lastOnline)
      RealtimeUpdates.pushToUser(targetUserId, [newUpdates])
    }
    return
  }

  if ("composeAction" in reason) {
    const { update, target } = reason.composeAction
    const updates = [{ updateComposeAction: update }]
    const newUpdates = getNewUpdatesForComposeAction(update.userId, target, update)

    if ("userId" in target) {
      sendUpdatesToUser(target.userId, updates)
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

/** Sends an array of updates to a connected user */
const sendUpdatesToUser = (userId: number, updates: TUpdateInfo[]) => {
  const message = createMessage({
    kind: ServerMessageKind.Message,
    payload: { updates },
  })
  connectionManager.sendToUser(userId, message)
}

const getNewUpdatesForComposeAction = (userId: number, peerId: TPeerInfo, action: TUpdateComposeAction) => {
  const currentUserId = userId
  // New update
  const newAction: UpdateComposeAction_ComposeAction =
    action.action == "typing" ? UpdateComposeAction_ComposeAction.TYPING : UpdateComposeAction_ComposeAction.NONE
  const updateComposeAction: Update = {
    update: {
      oneofKind: "updateComposeAction",
      updateComposeAction: {
        userId: BigInt(currentUserId),
        peerId: Encoders.peer(peerId),
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
