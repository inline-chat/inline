/**
 * Send Update
 *
 * - goal for this module is to make it easy for methods and other modules to send updates to relevant subscribers without leaking the logic for finding those inside the other modules
 * - Transient updates are updates that are not persisted to the database and are only sent to the relevant subscribers
 * - Persistent updates are updates that are persisted to the database and are kept in the database for all subscribers to get by some PTS
 */

import { DialogsModel } from "@in/server/db/models/dialogs"
import type { TUpdateInfo } from "@in/server/models"
import { connectionManager } from "@in/server/ws/connections"
import { createMessage, ServerMessageKind } from "@in/server/ws/protocol"

export type SendUpdateTransientReason =
  | {
      userPresenceUpdate: { userId: number; online: boolean; lastOnline: Date | null }
    }
  | {
      //...
    }

/** Sends an array of updates to a group of users tailored based on the reason, context, and user id */
export const sendTransientUpdateFor = async ({ reason }: { reason: SendUpdateTransientReason }) => {
  if ("userPresenceUpdate" in reason) {
    const { userId, online, lastOnline } = reason.userPresenceUpdate
    // 90/10 solution to get all users with private dialogs with the current user then send updates via connection manager to those users
    const userIds = await DialogsModel.getUserIdsWeHavePrivateDialogsWith({ userId })
    for (const userId of userIds) {
      // Generate updates for this user
      const updates = [
        {
          updateUserStatus: {
            userId,
            online,
            lastOnline: lastOnline?.getTime() ?? Date.now(),
          },
        },
      ]
      sendUpdatesToUser(userId, updates)
    }
  }

  // ....
}

/** Sends an array of updates to a connected user */
const sendUpdatesToUser = (userId: number, updates: TUpdateInfo[]) => {
  const message = createMessage({
    kind: ServerMessageKind.Message,
    payload: { updates },
  })
  connectionManager.sendToUser(userId, message)
}
