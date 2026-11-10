import { resolveOutputMode, type OutputMode } from "../vendor/agent-activity/index.js"
import { Method, type InlineSdkClient } from "@inline-chat/realtime-sdk"

export type { OutputMode }

/** Mode changes reach a running gateway within this long; the SDK drops the live pushes. */
export const OUTPUT_MODE_CACHE_TTL_MS = 30_000
const OUTPUT_MODE_LOOKUP_TIMEOUT_MS = 2_500
const MAX_CACHED_CHATS = 1_000

type ModeClient = Pick<InlineSdkClient, "invokeRaw">

type Cached = { mode: number | undefined; fetchedAt: number }

export type InlineOutputModeResolver = {
  /** The mode for a turn in `chatId`: the chat's override, else the bot's default, else Detailed. Never throws. */
  resolve(chatId: bigint): Promise<OutputMode>
}

/**
 * Reads the bot's own output mode (`getAgentSettings` for itself) and the
 * chat's override (`getAgentParticipations`) at turn start, each cached for
 * 30 s. A failed read keeps the last known value; with none, Detailed.
 */
export function createInlineOutputModeResolver(params: {
  client: ModeClient
  botUserId: bigint
  now?: () => number
  ttlMs?: number
  timeoutMs?: number
  onError?: (operation: "getAgentSettings" | "getAgentParticipations", error: unknown) => void
}): InlineOutputModeResolver {
  const now = params.now ?? Date.now
  const ttl = params.ttlMs ?? OUTPUT_MODE_CACHE_TTL_MS
  const timeoutMs = params.timeoutMs ?? OUTPUT_MODE_LOOKUP_TIMEOUT_MS
  let botDefault: Cached | undefined
  let botDefaultFetch: Promise<number | undefined> | undefined
  const overrides = new Map<string, Cached>()
  const overrideFetches = new Map<string, Promise<number | undefined>>()

  const withTimeout = async <T>(operation: Promise<T>): Promise<T> => {
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      return await Promise.race([
        operation,
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error("output mode lookup timed out")), timeoutMs)
        }),
      ])
    } finally {
      if (timer) clearTimeout(timer)
    }
  }

  const fetchDefault = async (): Promise<number | undefined> => {
    const result = await withTimeout(params.client.invokeRaw(Method.GET_AGENT_SETTINGS, {
      oneofKind: "getAgentSettings",
      // 0 is the caller: the bot reads its own settings.
      getAgentSettings: { botUserId: 0n },
    }))
    if (result.oneofKind !== "getAgentSettings") {
      throw new Error(`expected getAgentSettings result, got ${String(result.oneofKind)}`)
    }
    return result.getAgentSettings.settings?.defaultOutputMode
  }

  const fetchOverride = async (chatId: bigint): Promise<number | undefined> => {
    const result = await withTimeout(params.client.invokeRaw(Method.GET_AGENT_PARTICIPATIONS, {
      oneofKind: "getAgentParticipations",
      getAgentParticipations: { peerId: { type: { oneofKind: "chat", chat: { chatId } } } },
    }))
    if (result.oneofKind !== "getAgentParticipations") {
      throw new Error(`expected getAgentParticipations result, got ${String(result.oneofKind)}`)
    }
    return result.getAgentParticipations.participations
      .find((participation) => participation.botUserId === params.botUserId)?.outputMode
  }

  const readDefault = async (): Promise<number | undefined> => {
    if (botDefault && now() - botDefault.fetchedAt < ttl) return botDefault.mode
    botDefaultFetch ??= fetchDefault()
      .then((mode) => {
        botDefault = { mode, fetchedAt: now() }
        return mode
      })
      .catch((error: unknown) => {
        params.onError?.("getAgentSettings", error)
        return botDefault?.mode
      })
      .finally(() => {
        botDefaultFetch = undefined
      })
    return botDefaultFetch
  }

  const readOverride = async (chatId: bigint): Promise<number | undefined> => {
    const key = String(chatId)
    const cached = overrides.get(key)
    if (cached && now() - cached.fetchedAt < ttl) return cached.mode
    let pending = overrideFetches.get(key)
    if (!pending) {
      pending = fetchOverride(chatId)
        .then((mode) => {
          overrides.delete(key)
          overrides.set(key, { mode, fetchedAt: now() })
          while (overrides.size > MAX_CACHED_CHATS) {
            const oldest = overrides.keys().next().value
            if (oldest === undefined) break
            overrides.delete(oldest)
          }
          return mode
        })
        .catch((error: unknown) => {
          params.onError?.("getAgentParticipations", error)
          return overrides.get(key)?.mode
        })
        .finally(() => {
          overrideFetches.delete(key)
        })
      overrideFetches.set(key, pending)
    }
    return pending
  }

  return {
    async resolve(chatId) {
      const [defaultMode, override] = await Promise.all([readDefault(), readOverride(chatId)])
      return resolveOutputMode(defaultMode, override)
    },
  }
}
