import { setTimeout as delay } from "node:timers/promises"
import {
  inboundEventNeedsSenderResolution,
  normalizeInboundEvent,
  type GenericInboundEvent,
  type GenericSenderProfile,
  type Json,
} from "./contract.js"

type SenderResolution = { profile?: GenericSenderProfile; provenanceVerified: boolean }

// Match the Python adapter's structured-entity exemption. A display name, text
// username or the broad `mentioned` flag is not authority for this fast path.
export function explicitlyMentionsSelf(event: GenericInboundEvent, meId: string | null): boolean {
  if (!meId || (event.kind !== "message.new" && event.kind !== "message.edit")) return false
  const message = event.message as
    | { entities?: { entities?: Array<{ entity?: { oneofKind?: string; mention?: { userId?: bigint } } }> } }
    | undefined
  return (
    message?.entities?.entities?.some(
      (e) => e.entity?.oneofKind === "mention" && e.entity.mention?.userId?.toString() === meId
    ) ?? false
  )
}

export async function deliverInboundEvent(
  event: GenericInboundEvent,
  owner: {
    meId: string | null
    meUsername: string | null
    signal: AbortSignal
    resolveSender: (event: GenericInboundEvent) => Promise<SenderResolution>
    deliver: (event: Json) => Promise<void>
  }
): Promise<void> {
  const explicitMention = explicitlyMentionsSelf(event, owner.meId)
  while (!owner.signal.aborted) {
    const resolution = explicitMention
      ? { provenanceVerified: false }
      : inboundEventNeedsSenderResolution(event)
      ? await owner.resolveSender(event)
      : { provenanceVerified: true }
    owner.signal.throwIfAborted()
    if (
      !explicitMention &&
      !resolution.provenanceVerified &&
      (event.kind === "message.new" || event.kind === "message.edit")
    ) {
      // Unknown sender is deferred, not acknowledged as an intentional ignore.
      // The SDK owns this receipt and permits unrelated chats to keep moving.
      await delay(1_000, undefined, { signal: owner.signal })
      continue
    }
    const normalized = normalizeInboundEvent(event, owner.meId, resolution.profile, owner.meUsername)
    await owner.deliver(
      resolution.provenanceVerified
        ? normalized
        : { ...(normalized as Record<string, Json>), _inlineSenderProvenanceVerified: false }
    )
    return
  }
  owner.signal.throwIfAborted()
}
