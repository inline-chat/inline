import type { InputPeer, RichMessage, Update } from "@inline-chat/protocol/core"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { richMediaDependencies, normalizeRichMessage, RichTextValidationError } from "@in/server/modules/message/richText"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { maxRichDraftIdLength } from "@in/server/modules/message/richDraftLimits"

const defaultDraftTtlSeconds = 30
const maxDraftTtlSeconds = 120

export type RichMessageDraftUpdateInput = {
  inputPeer: InputPeer
  currentUserId: number
  senderUserId: number
  draftId: string
  richText?: RichMessage
  messageId?: bigint
  clear?: boolean
  now?: Date
  ttlSeconds?: number
}

export function buildRichMessageDraftUpdate(input: RichMessageDraftUpdateInput): Update {
  const draftId = input.draftId.trim()
  if (!draftId) {
    throw new RichTextValidationError("draft_id is required")
  }
  if (draftId.length > maxRichDraftIdLength) {
    throw new RichTextValidationError(`draft_id must be at most ${maxRichDraftIdLength} characters`)
  }

  const now = input.now ?? new Date()
  const requestedClear = input.clear ?? false
  const richText = requestedClear ? undefined : normalizeDraftRichText(input.richText)
  const clear = requestedClear || !richText
  const ttlSeconds = normalizeDraftTtlSeconds(input.ttlSeconds)

  return {
    date: encodeDateStrict(now),
    update: {
      oneofKind: "richMessageDraft",
      richMessageDraft: {
        draftId,
        peerId: encodePeerFromInputPeer({ inputPeer: input.inputPeer, currentUserId: input.currentUserId }),
        senderUserId: BigInt(input.senderUserId),
        messageId: input.messageId,
        richText,
        expiresAt: BigInt(Math.round(now.getTime() / 1000) + ttlSeconds),
        clear,
      },
    },
  }
}

export async function pushRichMessageDraftUpdate(input: RichMessageDraftUpdateInput): Promise<void> {
  const update = buildRichMessageDraftUpdate(input)
  const group = await getUpdateGroupFromInputPeer(input.inputPeer, { currentUserId: input.currentUserId })

  for (const userId of group.userIds) {
    RealtimeUpdates.pushToUser(userId, [update])
  }
}

function normalizeDraftTtlSeconds(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) {
    return defaultDraftTtlSeconds
  }

  return Math.min(maxDraftTtlSeconds, Math.max(1, Math.floor(value)))
}

function normalizeDraftRichText(richText: RichMessage | undefined): RichMessage | undefined {
  if (!richText) {
    return undefined
  }

  const normalized = normalizeRichMessage(richText, { allowThinking: true })
  const unresolvedMedia = richMediaDependencies(normalized).some((dep) => dep.kind === "public_url")
  if (unresolvedMedia) {
    throw new RichTextValidationError("rich message drafts cannot contain unresolved public media")
  }

  return normalized.blocks.length > 0 ? normalized : undefined
}
