import type { InputPeer, Update } from "@in/protocol/core"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"

// This will manage storing, pts, batching, etc.
export class Updates {
  static shared = new Updates()

  public async pushUpdate(updates: Update[], context: { peerId: InputPeer; currentUserId: number }) {
    const updateGroup = await getUpdateGroupFromInputPeer(context.peerId, { currentUserId: context.currentUserId })
    switch (updateGroup.type) {
      case "dmUsers": {
        const { userIds } = updateGroup
        for (const userId of userIds) {
          RealtimeUpdates.pushToUser(userId, updates)
        }
        break
      }

      case "threadUsers": {
        const { userIds } = updateGroup
        for (const userId of userIds) {
          RealtimeUpdates.pushToUser(userId, updates)
        }

        // Unsure if connection manager is up to date on space members this can fail
        // RealtimeUpdates.pushToSpace(spaceId, updates)
        break
      }
    }
  }
}

export let updatesModule = Updates.shared