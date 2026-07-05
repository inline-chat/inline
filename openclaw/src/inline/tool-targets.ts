import { normalizeInlineTarget } from "./normalize.js"

export type InlinePeerTarget = {
  peerId:
    | { type: { oneofKind: "chat"; chat: { chatId: bigint } } }
    | { type: { oneofKind: "user"; user: { userId: bigint } } }
  normalized: string
}

export type InlineCurrentSession = {
  target: InlinePeerTarget
  parentChatId: bigint | null
  threadId: bigint | null
}

export function parseInlineId(raw: unknown, label: string): bigint {
  if (typeof raw === "bigint") {
    if (raw < 0n) throw new Error(`inline tool: invalid ${label} "${raw.toString()}"`)
    return raw
  }
  if (typeof raw === "number") {
    if (!Number.isFinite(raw) || !Number.isInteger(raw) || raw < 0) {
      throw new Error(`inline tool: invalid ${label} "${String(raw)}"`)
    }
    return BigInt(raw)
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim()
    if (!trimmed) throw new Error(`inline tool: missing ${label}`)
    if (!/^[0-9]+$/.test(trimmed)) throw new Error(`inline tool: invalid ${label} "${raw}"`)
    return BigInt(trimmed)
  }
  throw new Error(`inline tool: missing ${label}`)
}

export function parseOptionalInlineId(raw: unknown, label: string): bigint | null {
  if (raw == null) return null
  if (typeof raw === "string" && !raw.trim()) return null
  return parseInlineId(raw, label)
}

export function parseInlineTarget(raw: string, label: string): InlinePeerTarget {
  const normalized = normalizeInlineTarget(raw) ?? raw.trim()
  const userMatch = normalized.match(/^user:([0-9]+)$/i)
  if (userMatch?.[1]) {
    return {
      normalized: `user:${userMatch[1]}`,
      peerId: {
        type: {
          oneofKind: "user",
          user: { userId: BigInt(userMatch[1]) },
        },
      },
    }
  }
  if (!/^[0-9]+$/.test(normalized)) {
    throw new Error(`inline tool: invalid ${label} "${raw}"`)
  }
  return {
    normalized,
    peerId: {
      type: {
        oneofKind: "chat",
        chat: { chatId: BigInt(normalized) },
      },
    },
  }
}

export function parseCurrentInlineSession(ctx: {
  messageChannel?: string
  sessionKey?: string
}): InlineCurrentSession | null {
  if ((ctx.messageChannel ?? "").trim().toLowerCase() !== "inline") return null
  const sessionKey = ctx.sessionKey?.trim()
  if (!sessionKey) return null

  const explicitMatch = sessionKey.match(/^agent:[^:]+:inline:(chat|group|user|direct):([0-9]+)(?::thread:([0-9]+))?$/i)
  if (explicitMatch?.[1] && explicitMatch[2]) {
    const kind = explicitMatch[1].toLowerCase()
    const threadId = explicitMatch[3]
    if ((kind === "chat" || kind === "group") && threadId) {
      return {
        target: parseInlineTarget(threadId, "current chat"),
        parentChatId: parseInlineId(explicitMatch[2], "current parent chat"),
        threadId: parseInlineId(threadId, "current thread"),
      }
    }
    return {
      target: parseInlineTarget(
        kind === "user" || kind === "direct" ? `user:${explicitMatch[2]}` : explicitMatch[2],
        "current chat",
      ),
      parentChatId: null,
      threadId: null,
    }
  }

  const legacyMatch = sessionKey.match(/^agent:[^:]+:inline:([0-9]+)(?::thread:([0-9]+))?$/i)
  if (legacyMatch?.[1]) {
    return {
      target: parseInlineTarget(legacyMatch[2] ?? legacyMatch[1], "current chat"),
      parentChatId: legacyMatch[2] ? parseInlineId(legacyMatch[1], "current parent chat") : null,
      threadId: legacyMatch[2] ? parseInlineId(legacyMatch[2], "current thread") : null,
    }
  }

  return null
}

export function parseCurrentInlineTarget(ctx: {
  messageChannel?: string
  sessionKey?: string
}): InlinePeerTarget | null {
  return parseCurrentInlineSession(ctx)?.target ?? null
}

export function readStringCandidate(...values: unknown[]): string | undefined {
  for (const value of values) {
    if (typeof value !== "string") continue
    const trimmed = value.trim()
    if (trimmed) return trimmed
  }
  return undefined
}
