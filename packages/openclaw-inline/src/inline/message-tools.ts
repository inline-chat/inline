import {
  jsonResult,
  type AnyAgentTool,
  type OpenClawConfig,
} from "openclaw/plugin-sdk"
import { InlineSdkClient, Method } from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { normalizeInlineTarget } from "./normalize.js"

type InlineMessageToolContext = {
  config?: OpenClawConfig
  agentAccountId?: string
  sessionKey?: string
  messageChannel?: string
}

type InlineNudgeToolArgs = {
  to?: string
  target?: string
  chatId?: string
  userId?: string
  message?: string
  text?: string
  accountId?: string
}

type InlineForwardToolArgs = {
  to?: string
  target?: string
  chatId?: string
  userId?: string
  from?: string
  source?: string
  fromChatId?: string
  sourceChatId?: string
  fromUserId?: string
  sourceUserId?: string
  messageId?: string
  messageIds?: string[] | string
  shareForwardHeader?: boolean
  accountId?: string
}

type InlinePeerTarget = {
  peerId:
    | { type: { oneofKind: "chat"; chat: { chatId: bigint } } }
    | { type: { oneofKind: "user"; user: { userId: bigint } } }
  normalized: string
}

const InlineNudgeToolParameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    to: {
      type: "string",
      description:
        "Optional Inline target (`chat:<id>`, bare chat id, or `user:<id>`). Defaults to the current Inline chat when available.",
    },
    target: {
      type: "string",
      description: "Alias for `to`.",
    },
    chatId: {
      type: "string",
      description: "Explicit chat id target alias.",
    },
    userId: {
      type: "string",
      description: "Explicit user id target alias.",
    },
    message: {
      type: "string",
      description: "Optional accompanying text.",
    },
    text: {
      type: "string",
      description: "Alias for `message`.",
    },
    accountId: {
      type: "string",
      description: "Optional Inline account id override.",
    },
  },
} as const

const InlineForwardToolParameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    to: {
      type: "string",
      description: "Destination Inline target (`chat:<id>`, bare chat id, or `user:<id>`).",
    },
    target: {
      type: "string",
      description: "Alias for `to`.",
    },
    chatId: {
      type: "string",
      description: "Explicit destination chat id alias.",
    },
    userId: {
      type: "string",
      description: "Explicit destination user id alias.",
    },
    from: {
      type: "string",
      description:
        "Optional source Inline target. Defaults to the current Inline chat when available.",
    },
    source: {
      type: "string",
      description: "Alias for `from`.",
    },
    fromChatId: {
      type: "string",
      description: "Explicit source chat id alias.",
    },
    sourceChatId: {
      type: "string",
      description: "Alias for `fromChatId`.",
    },
    fromUserId: {
      type: "string",
      description: "Explicit source user id alias.",
    },
    sourceUserId: {
      type: "string",
      description: "Alias for `fromUserId`.",
    },
    messageId: {
      type: "string",
      description: "Single message id to forward.",
    },
    messageIds: {
      oneOf: [
        { type: "string" },
        { type: "array", items: { type: "string" } },
      ],
      description: "One or more source message ids to forward.",
    },
    shareForwardHeader: {
      type: "boolean",
      description: "Whether forwarded messages should include the original forward header (default true).",
    },
    accountId: {
      type: "string",
      description: "Optional Inline account id override.",
    },
  },
  required: ["to"],
} as const

function parseInlineId(raw: unknown, label: string): bigint {
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

function parseInlineTarget(raw: string, label: string): InlinePeerTarget {
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

function parseCurrentInlineTarget(ctx: Pick<InlineMessageToolContext, "messageChannel" | "sessionKey">):
  | InlinePeerTarget
  | null {
  if ((ctx.messageChannel ?? "").trim().toLowerCase() !== "inline") {
    return null
  }
  const sessionKey = ctx.sessionKey?.trim()
  if (!sessionKey) return null

  const explicitMatch = sessionKey.match(/^agent:[^:]+:inline:(chat|user):([0-9]+)(?::thread:[^:]+)?$/i)
  if (explicitMatch?.[1] && explicitMatch[2]) {
    return parseInlineTarget(
      explicitMatch[1].toLowerCase() === "user" ? `user:${explicitMatch[2]}` : explicitMatch[2],
      "current chat",
    )
  }

  const legacyMatch = sessionKey.match(/^agent:[^:]+:inline:([0-9]+)(?::thread:[^:]+)?$/i)
  if (legacyMatch?.[1]) {
    return parseInlineTarget(legacyMatch[1], "current chat")
  }

  return null
}

function readStringCandidate(...values: unknown[]): string | undefined {
  for (const value of values) {
    if (typeof value !== "string") continue
    const trimmed = value.trim()
    if (trimmed) return trimmed
  }
  return undefined
}

function resolvePeerTarget(params: {
  label: string
  direct?: string | undefined
  chatId?: string | undefined
  userId?: string | undefined
  fallback?: InlinePeerTarget | null | undefined
}): { target: InlinePeerTarget; usedFallback: boolean } {
  if (params.direct) {
    return {
      target: parseInlineTarget(params.direct, params.label),
      usedFallback: false,
    }
  }
  if (params.userId) {
    const userId = parseInlineId(params.userId, `${params.label} userId`)
    return {
      target: parseInlineTarget(`user:${String(userId)}`, params.label),
      usedFallback: false,
    }
  }
  if (params.chatId) {
    const chatId = parseInlineId(params.chatId, `${params.label} chatId`)
    return {
      target: parseInlineTarget(String(chatId), params.label),
      usedFallback: false,
    }
  }
  if (params.fallback) {
    return {
      target: params.fallback,
      usedFallback: true,
    }
  }
  throw new Error(`inline tool: missing ${params.label}`)
}

function parseMessageIds(raw: InlineForwardToolArgs): bigint[] {
  const values: string[] = []

  const pushValue = (value: unknown) => {
    if (value == null) return
    if (Array.isArray(value)) {
      for (const item of value) pushValue(item)
      return
    }
    if (typeof value === "string") {
      const trimmed = value.trim()
      if (!trimmed) return
      for (const chunk of trimmed.split(",")) {
        const token = chunk.trim()
        if (token) values.push(token)
      }
      return
    }
    if (typeof value === "number" || typeof value === "bigint") {
      values.push(String(value))
      return
    }
    throw new Error("inline tool: invalid messageIds")
  }

  pushValue(raw.messageIds)
  pushValue(raw.messageId)

  if (values.length === 0) {
    throw new Error("inline tool: forward requires messageId or messageIds")
  }

  return values.map((value) => parseInlineId(value, "messageId"))
}

function extractFirstMessageId(updates: unknown): string | null {
  if (!Array.isArray(updates)) return null
  for (const update of updates) {
    const record = update as {
      update?: {
        oneofKind?: string
        newMessage?: { message?: { id?: bigint | number | string } }
      }
    }
    if (record.update?.oneofKind !== "newMessage") continue
    const messageId = record.update.newMessage?.message?.id
    if (typeof messageId === "bigint") return messageId.toString()
    if (typeof messageId === "number" && Number.isFinite(messageId)) return String(Math.trunc(messageId))
    if (typeof messageId === "string" && messageId.trim()) return messageId.trim()
  }
  return null
}

async function withInlineClient<T>(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  fn: (client: InlineSdkClient, resolvedAccountId: string) => Promise<T>
}): Promise<T> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }
  const token = await resolveInlineToken(account)
  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })
  await client.connect()
  try {
    return await params.fn(client, account.accountId)
  } finally {
    await client.close().catch(() => {})
  }
}

function createInlineNudgeTool(ctx: InlineMessageToolContext): AnyAgentTool {
  return {
    name: "inline_nudge",
    label: "Inline Nudge",
    description:
      "Send an Inline nudge to a chat or user. If invoked from an Inline conversation, omitting the target defaults to the current chat.",
    parameters: InlineNudgeToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      if (!ctx.config) {
        throw new Error("inline_nudge: missing OpenClaw config")
      }

      const args = rawArgs as InlineNudgeToolArgs
      const fallbackTarget = parseCurrentInlineTarget(ctx)
      const { target, usedFallback } = resolvePeerTarget({
        label: "target",
        direct: readStringCandidate(args.to, args.target),
        chatId: args.chatId,
        userId: args.userId,
        fallback: fallbackTarget,
      })
      const message = readStringCandidate(args.message, args.text)

      return await withInlineClient({
        cfg: ctx.config,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
        fn: async (client, resolvedAccountId) => {
          const result = await client.invokeRaw(Method.SEND_MESSAGE, {
            oneofKind: "sendMessage",
            sendMessage: {
              peerId: target.peerId,
              ...(message ? { message } : {}),
              media: {
                media: {
                  oneofKind: "nudge",
                  nudge: {},
                },
              },
            },
          })
          const messageId =
            result.oneofKind === "sendMessage" ? extractFirstMessageId(result.sendMessage.updates) : null

          return jsonResult({
            ok: true,
            accountId: resolvedAccountId,
            nudged: true,
            target: target.normalized,
            usedCurrentChatDefault: usedFallback,
            message: message ?? null,
            messageId,
          })
        },
      })
    },
  } as AnyAgentTool
}

function createInlineForwardTool(ctx: InlineMessageToolContext): AnyAgentTool {
  return {
    name: "inline_forward",
    label: "Inline Forward",
    description:
      "Forward one or more Inline message ids from a source chat/user to another chat/user. If the source is omitted in an Inline conversation, it defaults to the current chat.",
    parameters: InlineForwardToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      if (!ctx.config) {
        throw new Error("inline_forward: missing OpenClaw config")
      }

      const args = rawArgs as InlineForwardToolArgs
      const fallbackSource = parseCurrentInlineTarget(ctx)
      const { target: destination } = resolvePeerTarget({
        label: "destination target",
        direct: readStringCandidate(args.to, args.target),
        chatId: args.chatId,
        userId: args.userId,
      })
      const { target: source, usedFallback } = resolvePeerTarget({
        label: "source target",
        direct: readStringCandidate(args.from, args.source),
        chatId: readStringCandidate(args.fromChatId, args.sourceChatId),
        userId: readStringCandidate(args.fromUserId, args.sourceUserId),
        fallback: fallbackSource,
      })
      const messageIds = parseMessageIds(args)

      return await withInlineClient({
        cfg: ctx.config,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
        fn: async (client, resolvedAccountId) => {
          const result = await client.invokeRaw(Method.FORWARD_MESSAGES, {
            oneofKind: "forwardMessages",
            forwardMessages: {
              fromPeerId: source.peerId,
              toPeerId: destination.peerId,
              messageIds,
              ...(typeof args.shareForwardHeader === "boolean"
                ? { shareForwardHeader: args.shareForwardHeader }
                : {}),
            },
          })
          const forwardedMessageId =
            result.oneofKind === "forwardMessages"
              ? extractFirstMessageId(result.forwardMessages.updates)
              : null

          return jsonResult({
            ok: true,
            accountId: resolvedAccountId,
            from: source.normalized,
            to: destination.normalized,
            messageIds: messageIds.map((messageId) => messageId.toString()),
            shareForwardHeader:
              typeof args.shareForwardHeader === "boolean" ? args.shareForwardHeader : true,
            usedCurrentChatDefault: usedFallback,
            forwardedMessageId,
          })
        },
      })
    },
  } as AnyAgentTool
}

export function createInlineMessageTools(ctx: InlineMessageToolContext): AnyAgentTool[] {
  if (!ctx.config) return []
  return [createInlineNudgeTool(ctx), createInlineForwardTool(ctx)]
}
