import { setTimeout as delay } from "node:timers/promises"
import {
  inboundEventIsServiceMessage,
  inboundEventNeedsSenderResolution,
  normalizeInboundEvent,
  type GenericInboundEvent,
  type GenericSenderProfile,
  type Json,
} from "./contract.js"

type SenderResolution = { profile?: GenericSenderProfile; provenanceVerified: boolean }

const MENTION_SENDER_LOOKUP_MS = 2_000

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

// A mention reaches the agent even while the directory is down, so it never waits on a retry.
// The turn still needs its sender when the lookup works: a bot's answer only gets back to
// another bot by quoting it, and tools that only people may use check the sender.
function resolveMentionSender(
  event: GenericInboundEvent,
  owner: {
    signal: AbortSignal
    mentionSenderLookupMs?: number
    resolveSender: (event: GenericInboundEvent) => Promise<SenderResolution>
  },
): Promise<SenderResolution> {
  const unverified: SenderResolution = { provenanceVerified: false }
  return Promise.race([
    owner.resolveSender(event).catch(() => unverified),
    delay(owner.mentionSenderLookupMs ?? MENTION_SENDER_LOOKUP_MS, unverified, { signal: owner.signal, ref: false }),
  ])
}

export async function deliverInboundEvent(
  event: GenericInboundEvent,
  owner: {
    meId: string | null
    meUsername: string | null
    signal: AbortSignal
    mentionSenderLookupMs?: number
    resolveSender: (event: GenericInboundEvent) => Promise<SenderResolution>
    deliver: (event: Json) => Promise<void>
  }
): Promise<void> {
  // Resolving this intentional ignore completes the SDK receipt without a Python ACK.
  if (inboundEventIsServiceMessage(event)) return
  const explicitMention = explicitlyMentionsSelf(event, owner.meId)
  while (!owner.signal.aborted) {
    const resolution = explicitMention
      ? await resolveMentionSender(event, owner)
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
