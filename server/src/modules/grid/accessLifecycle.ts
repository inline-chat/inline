import { notifyGridChanged } from "@in/server/modules/grid/realtime"
import {
  removeGridMemberPresence,
  removeGridSessionPresence,
  type GridPresenceRemovalState,
} from "@in/server/modules/grid/roomLifecycle"
import { sendMessageToRealtimeUser } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"

const log = new Log("grid.accessLifecycle")

/** Removes all Grid/media authority after Space membership is revoked. */
export async function removeGridMemberAccess(spaceId: number, userId: number) {
  const state = await removeGridMemberPresence(spaceId, userId)

  await finishGridMemberAccess(state, spaceId, userId)
}

/** Publishes member-revocation effects after the authority transaction commits. */
export async function finishGridMemberAccess(
  state: GridPresenceRemovalState,
  spaceId: number,
  userId: number,
) {
  await Promise.all([
    notifyGridChanged(state),
    sendMessageToRealtimeUser(userId, {
      oneofKind: "grid",
      grid: {
        event: {
          oneofKind: "accessRevoked",
          accessRevoked: { spaceId: BigInt(spaceId) },
        },
      },
    }).catch((error) => {
      // Membership and media authority are already committed. The snapshot is
      // authoritative, so a broken socket must not make deletion appear to
      // have failed after the durable state transition succeeded.
      log.warn("Failed to send committed Grid access-revoked notification", {
        spaceId,
        userId,
        error,
      })
    }),
  ])
  log.info("GRID_TRACE phase=member_access_revoked", {
    spaceId,
    roomId: state.changedRoomId,
    userId,
    hadActiveConnection: state.activeConnection !== undefined,
  })
}

/**
 * Removes presence owned by one app session. A newer session that has already
 * claimed the user's global avatar is untouched.
 */
export async function removeGridSessionAccess(userId: number, ownerSessionId: number) {
  const state = await removeGridSessionPresence(userId, ownerSessionId)
  await finishGridSessionAccess(state, userId, ownerSessionId)
}

/** Publishes realtime effects after transactional presence/provider ownership commits. */
export async function finishGridSessionAccess(
  state: GridPresenceRemovalState,
  userId: number,
  ownerSessionId: number,
) {
  if (!state.removedPresence) return
  await notifyGridChanged(state)
  log.info("GRID_TRACE phase=session_access_revoked", {
    roomId: state.changedRoomId,
    userId,
    ownerSessionId,
    hadActiveConnection: state.activeConnection !== undefined,
  })
}
