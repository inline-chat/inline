import type { GridMutationState } from "@in/server/modules/grid/roomLifecycle"
import { sendMessageToRealtimeSpace } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"

const log = new Log("grid.realtime")

export async function notifyGridChanged(state: GridMutationState) {
  const startedAt = Date.now()
  try {
    if (state.affectedSpaceIds.size > 0) {
      const payload = {
        oneofKind: "grid" as const,
        grid: {
          event: {
            oneofKind: "changed" as const,
            changed: {
              spaceIds: [...state.affectedSpaceIds].map(BigInt),
              roomId: state.changedRoomId === undefined ? undefined : BigInt(state.changedRoomId),
            },
          },
        },
      }
      await Promise.all([...state.affectedSpaceIds].map((spaceId) => sendMessageToRealtimeSpace(spaceId, payload)))
    }
  } catch (error) {
    // Grid snapshots are authoritative and clients refetch after wake/network
    // changes. A process-local ephemeral push must never turn a committed room
    // mutation into an RPC failure.
    Log.shared.warn("Failed to send committed Grid change notification", {
      roomId: state.changedRoomId,
      spaceIds: [...state.affectedSpaceIds],
      error,
    })
  }
  log.debug("GRID_TRACE phase=changed_push_done", {
    roomId: state.changedRoomId,
    spaceIds: [...state.affectedSpaceIds],
    endedConnectionCount: state.endedConnections.length,
    participantRevocationCount: state.participantRevocations?.length ?? 0,
    elapsedMs: Date.now() - startedAt,
  })
}

export async function notifyGridSpaceChanged(spaceId: number) {
  await notifyGridChanged({ affectedSpaceIds: new Set([spaceId]), endedConnections: [] })
}
