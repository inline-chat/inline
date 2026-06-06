import { BotPresenceState_Kind, type BotPresenceState } from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"

const states = new Map<string, BotPresenceState>()
const maxCommentLength = 30

const validKinds = new Set<BotPresenceState_Kind>([
  BotPresenceState_Kind.IDLE,
  BotPresenceState_Kind.HAPPY,
  BotPresenceState_Kind.WAVING,
  BotPresenceState_Kind.JUMPING,
  BotPresenceState_Kind.FAILED,
  BotPresenceState_Kind.WAITING,
  BotPresenceState_Kind.RUNNING,
  BotPresenceState_Kind.REVIEW,
])

export function getBotPresenceState(botUserId: number, chatId: number): BotPresenceState {
  return states.get(key(botUserId, chatId)) ?? { kind: BotPresenceState_Kind.IDLE }
}

export function setBotPresenceState(botUserId: number, chatId: number, state: BotPresenceState): BotPresenceState {
  const normalized = normalizeBotPresenceState(state)
  states.set(key(botUserId, chatId), normalized)
  return normalized
}

export function normalizeBotPresenceState(state: BotPresenceState): BotPresenceState {
  const kind =
    state.kind === BotPresenceState_Kind.KIND_UNSPECIFIED || state.kind === BotPresenceState_Kind.HIDDEN
      ? BotPresenceState_Kind.IDLE
      : state.kind
  if (!validKinds.has(kind)) {
    throw RealtimeRpcError.BadRequest()
  }

  const comment = normalizeComment(state.comment)
  return comment ? { kind, comment } : { kind }
}

function key(botUserId: number, chatId: number): string {
  return `${botUserId}:${chatId}`
}

function normalizeComment(value: string | undefined): string | undefined {
  const text = value?.replace(/\s+/g, " ").trim()
  if (!text) return undefined
  return Array.from(text).slice(0, maxCommentLength).join("")
}
