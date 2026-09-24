import { randomUUID } from "node:crypto"
import { BotPresenceState_Kind, type BotPresenceState } from "@inline-chat/protocol/core"
import { internalMessaging } from "@in/server/modules/internalMessaging/service"
import { botPresenceStateTimeoutMs, getBotPresenceState, normalizeBotPresenceState, setBotPresenceState } from "./state"

type SharedValue = { activityId: string; state: BotPresenceState; expiresAt: number }
export type SharedBotPresence = { status: "available" | "unavailable"; activityId?: string; state: BotPresenceState; remainingMs: number }
const key = (botUserId: number, chatId: number) => `bot-presence:${botUserId}:${chatId}`
const idle = (): BotPresenceState => ({ kind: BotPresenceState_Kind.IDLE })

/** Redis expiry is authoritative; local state only keeps the existing graceful display during broker loss. */
export async function setSharedBotPresence(botUserId: number, chatId: number, input: BotPresenceState): Promise<{ state: BotPresenceState; activityId: string }> {
  const state = normalizeBotPresenceState(input)
  const activityId = randomUUID()
  setBotPresenceState(botUserId, chatId, state, Date.now(), activityId)
  const ttlMs = botPresenceStateTimeoutMs(state)
  if (ttlMs === undefined) {
    await internalMessaging.deleteEphemeral(key(botUserId, chatId))
  } else {
    await internalMessaging.setEphemeral(key(botUserId, chatId), JSON.stringify({ activityId, state, expiresAt: Date.now() + ttlMs }), ttlMs)
  }
  return { state, activityId }
}

export async function getSharedBotPresence(botUserId: number, chatId: number): Promise<SharedBotPresence> {
  const value = await internalMessaging.getEphemeral(key(botUserId, chatId))
  if (value === undefined) return { status: "unavailable", state: getBotPresenceState(botUserId, chatId), remainingMs: 0 }
  if (value === null) return { status: "available", state: idle(), remainingMs: 0 }
  try {
    const parsed: unknown = JSON.parse(value)
    if (!isSharedValue(parsed)) return { status: "available", state: idle(), remainingMs: 0 }
    const remainingMs = Math.max(0, parsed.expiresAt - Date.now())
    if (remainingMs === 0) return { status: "available", state: idle(), remainingMs: 0 }
    return { status: "available", activityId: parsed.activityId, state: normalizeBotPresenceState(parsed.state), remainingMs }
  } catch { return { status: "available", state: idle(), remainingMs: 0 } }
}

function isSharedValue(value: unknown): value is SharedValue {
  if (!value || typeof value !== "object") return false
  const row = value as Partial<SharedValue>
  return typeof row.activityId === "string" && Number.isSafeInteger(row.expiresAt) &&
    !!row.state && typeof row.state.kind === "number" &&
    (row.state.comment === undefined || typeof row.state.comment === "string")
}
