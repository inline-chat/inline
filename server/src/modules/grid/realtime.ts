import type { GridMutationState } from "@in/server/modules/grid/roomLifecycle"
import { sendMessageToRealtimeSpace } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { internalMessaging } from "@in/server/modules/internalMessaging/service"
import { SpaceId } from "@in/server/core/schema/identifiers"
import { outboundPublications, type OutboundPublication } from "@in/server/modules/internalMessaging/outbound"

const log = new Log("grid.realtime")
export const maxConcurrentGridSpaceDeliveries = 8

class GridChangedPublication implements OutboundPublication {
  readonly key: string

  constructor(
    private readonly spaceId: number,
    private roomId: number | undefined,
  ) {
    this.key = `grid-changed:${spaceId}`
  }

  async run(): Promise<void> {
    await internalMessaging.publish({
      target: { kind: "cluster" },
      event: { kind: "GridChanged", spaceId: SpaceId.make(this.spaceId), roomId: this.roomId },
    })
  }

  merge(next: OutboundPublication): void {
    if (!(next instanceof GridChangedPublication) || next.key !== this.key) {
      throw new Error("Grid change publication merged with an incompatible outbound hint")
    }
    this.roomId = next.roomId
  }
}

export async function notifyGridChanged(state: GridMutationState) {
  const startedAt = Date.now()
  try {
    if (state.affectedSpaceIds.size > 0) {
      const spaceIds = [...state.affectedSpaceIds]
      const payload = {
        oneofKind: "grid" as const,
        grid: {
          event: {
            oneofKind: "changed" as const,
            changed: {
              spaceIds: spaceIds.map(BigInt),
              roomId: state.changedRoomId === undefined ? undefined : BigInt(state.changedRoomId),
            },
          },
        },
      }
      try {
        const failures: unknown[] = []
        for (let offset = 0; offset < spaceIds.length; offset += maxConcurrentGridSpaceDeliveries) {
          const results = await Promise.allSettled(spaceIds
            .slice(offset, offset + maxConcurrentGridSpaceDeliveries)
            .map((spaceId) => sendMessageToRealtimeSpace(spaceId, payload)))
          for (const result of results) {
            if (result.status === "rejected") failures.push(result.reason)
          }
        }
        if (failures.length > 0) throw new AggregateError(failures, "One or more local Grid deliveries failed")
      } finally {
        // Remote nodes can recover from the authoritative Grid snapshot. Keep
        // the hint owned and bounded, and enqueue even if local delivery failed.
        for (const spaceId of spaceIds) {
          outboundPublications.enqueue(new GridChangedPublication(spaceId, state.changedRoomId))
        }
      }
    }
  } catch (error) {
    // Grid snapshots are authoritative and clients refetch after wake/network
    // changes. An ephemeral push must never turn a committed room
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

export function subscribeGridChangeHints(): () => void {
  return internalMessaging.on("GridChanged", async ({ event }) => {
    // Reuse current membership checks on this node, without republishing.
    await sendMessageToRealtimeSpace(event.spaceId, {
      oneofKind: "grid",
      grid: { event: { oneofKind: "changed", changed: {
        spaceIds: [BigInt(event.spaceId)],
        roomId: event.roomId === undefined ? undefined : BigInt(event.roomId),
      } } },
    })
  })
}

export async function notifyGridSpaceChanged(spaceId: number) {
  await notifyGridChanged({ affectedSpaceIds: new Set([spaceId]), endedConnections: [] })
}
