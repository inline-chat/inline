import { gridPresence } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { and, eq, gt, sql } from "drizzle-orm"

/**
 * Stores transient avatar state beside its authoritative leased presence.
 *
 * This is intentionally not an update bucket: room snapshots can repair a
 * missed ephemeral push, while row deletion still clears the state on leave,
 * lease expiry, session revocation, or Space access loss. Keeping it in
 * Postgres makes that repair path correct across server workers and restarts.
 */
export async function setGridAvatarMicrophoneState(
  tx: Transaction,
  input: {
    userId: number
    ownerSessionId: number
    roomId: number
    enabled: boolean
  },
): Promise<{ membershipId: string; revision: number } | undefined> {
  const updated = await tx
    .update(gridPresence)
    .set({
      microphoneEnabled: input.enabled,
      microphoneRevision: sql`${gridPresence.microphoneRevision} + 1`,
    })
    .where(
      and(
        eq(gridPresence.userId, input.userId),
        eq(gridPresence.ownerSessionId, input.ownerSessionId),
        eq(gridPresence.roomId, input.roomId),
        gt(gridPresence.leaseExpiresAt, new Date()),
      ),
    )
    .returning({
      membershipId: gridPresence.mediaMembershipId,
      revision: gridPresence.microphoneRevision,
    })
  return updated[0]
}
