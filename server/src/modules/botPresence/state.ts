import { BotPresenceState_Kind, type BotPresenceState } from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"

type BotPresenceEntry = {
  state: BotPresenceState
  expiresAt?: number
}

const states = new Map<string, BotPresenceEntry>()
const maxCommentLength = 30
export const botPresenceActiveStateTtlMs = 20 * 1000
export const botPresenceCommentStateTtlMs = 60 * 1000

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

export function getBotPresenceState(botUserId: number, chatId: number, now = Date.now()): BotPresenceState {
  const entry = states.get(key(botUserId, chatId))
  if (!entry || isExpired(entry, now)) {
    return idleState()
  }

  return copyState(entry.state)
}

export function setBotPresenceState(
  botUserId: number,
  chatId: number,
  state: BotPresenceState,
  now = Date.now(),
): BotPresenceState {
  const normalized = normalizeBotPresenceState(state)
  const entryKey = key(botUserId, chatId)
  const timeoutMs = botPresenceStateTimeoutMs(normalized)

  if (normalized.kind === BotPresenceState_Kind.IDLE && !normalized.comment) {
    states.delete(entryKey)
    return normalized
  }

  states.set(entryKey, {
    state: copyState(normalized),
    ...(timeoutMs != null ? { expiresAt: now + timeoutMs } : {}),
  })

  return normalized
}

export function expireBotPresenceState(botUserId: number, chatId: number, now = Date.now()): BotPresenceState | undefined {
  const entryKey = key(botUserId, chatId)
  const entry = states.get(entryKey)
  if (!entry || !isExpired(entry, now)) {
    return undefined
  }

  states.delete(entryKey)
  return idleState()
}

export function botPresenceStateTimeoutMs(state: BotPresenceState): number | undefined {
  if (state.comment) {
    return botPresenceCommentStateTtlMs
  }

  return state.kind === BotPresenceState_Kind.IDLE ? undefined : botPresenceActiveStateTtlMs
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

function isExpired(entry: BotPresenceEntry, now: number): boolean {
  return entry.expiresAt != null && entry.expiresAt <= now
}

function idleState(): BotPresenceState {
  return { kind: BotPresenceState_Kind.IDLE }
}

function copyState(state: BotPresenceState): BotPresenceState {
  return state.comment ? { kind: state.kind, comment: state.comment } : { kind: state.kind }
}

function key(botUserId: number, chatId: number): string {
  return `${botUserId}:${chatId}`
}

function normalizeComment(value: string | undefined): string | undefined {
  const text = value?.replace(/\s+/g, " ").trim()
  if (!text) return undefined
  return Array.from(text).slice(0, maxCommentLength).join("")
}
