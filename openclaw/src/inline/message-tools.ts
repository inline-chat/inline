import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { BotPresenceState_Kind, InlineSdkClient, Method } from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { sanitizeInlineVisibleText } from "./outbound-sanitize.js"
import {
  parseCurrentInlineTarget,
  parseInlineId,
  parseInlineTarget,
  readStringCandidate,
  type InlinePeerTarget,
} from "./tool-targets.js"
import { jsonResult } from "../openclaw-compat.js"

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

const INLINE_BOT_PRESENCE_COMMENT_MAX_LENGTH = 30
const INLINE_BOT_PRESENCE_KINDS = [
  "idle",
  "happy",
  "waving",
  "jumping",
  "failed",
  "waiting",
  "running",
  "review",
] as const

type InlineBotPresenceKind = (typeof INLINE_BOT_PRESENCE_KINDS)[number]

type InlineBotPresenceToolArgs = {
  action?: string
  kind?: string
  comment?: string
  to?: string
  target?: string
  chatId?: string
  userId?: string
  accountId?: string
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

const InlineBotPresenceToolParameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    action: {
      type: "string",
      enum: ["set", "get"],
      description: "Presence operation. Defaults to `set`; use `get` to read the current bot avatar/state for a peer.",
    },
    kind: {
      type: "string",
      enum: INLINE_BOT_PRESENCE_KINDS,
      description:
        "Body state for your on-screen Inline character. Use waving for greetings/attention, jumping for delight/completion, review for thinking, waiting for user input, running for active work, failed when blocked/disappointed, happy for positive settled moments, and idle only when neutral is intentionally useful.",
    },
    comment: {
      type: "string",
      maxLength: INLINE_BOT_PRESENCE_COMMENT_MAX_LENGTH,
      description:
        "Tiny generated thought bubble from your actual current mood, process, status, request, nudge, or aside. Keep it casual, characterful, and under 30 characters; text or one/two emojis are both fine. It supplements the chat answer and should not replace substantive content.",
    },
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
    accountId: {
      type: "string",
      description: "Optional Inline account id override.",
    },
  },
} as const

const GET_BOT_PRESENCE_METHOD =
  typeof (Method as Record<string, unknown>).GET_BOT_PRESENCE === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_BOT_PRESENCE) &&
  ((Method as Record<string, unknown>).GET_BOT_PRESENCE as number) > 0
    ? ((Method as Record<string, unknown>).GET_BOT_PRESENCE as Method)
    : (58 as Method)
const SET_BOT_PRESENCE_STATE_METHOD =
  typeof (Method as Record<string, unknown>).SET_BOT_PRESENCE_STATE === "number" &&
  Number.isInteger((Method as Record<string, unknown>).SET_BOT_PRESENCE_STATE) &&
  ((Method as Record<string, unknown>).SET_BOT_PRESENCE_STATE as number) > 0
    ? ((Method as Record<string, unknown>).SET_BOT_PRESENCE_STATE as Method)
    : (59 as Method)

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

function normalizeInlineBotPresenceKind(value: unknown): InlineBotPresenceKind {
  if (typeof value !== "string") {
    throw new Error("inline_bot_presence: `kind` is required")
  }

  const normalized = value.trim().toLowerCase()
  for (const kind of INLINE_BOT_PRESENCE_KINDS) {
    if (kind === normalized) return kind
  }

  throw new Error(`inline_bot_presence: invalid kind "${value}"`)
}

function resolveInlineBotPresenceAction(args: InlineBotPresenceToolArgs): "set" | "get" {
  const action = typeof args.action === "string" ? args.action.trim().toLowerCase() : ""
  if (!action || action === "set" || action === "update") return "set"
  if (action === "get" || action === "read" || action === "status") return "get"
  throw new Error(`inline_bot_presence: invalid action "${args.action}"`)
}

function botPresenceStateKind(kind: InlineBotPresenceKind): BotPresenceState_Kind {
  switch (kind) {
    case "idle":
      return BotPresenceState_Kind.IDLE
    case "happy":
      return BotPresenceState_Kind.HAPPY
    case "waving":
      return BotPresenceState_Kind.WAVING
    case "jumping":
      return BotPresenceState_Kind.JUMPING
    case "failed":
      return BotPresenceState_Kind.FAILED
    case "waiting":
      return BotPresenceState_Kind.WAITING
    case "running":
      return BotPresenceState_Kind.RUNNING
    case "review":
      return BotPresenceState_Kind.REVIEW
  }
}

function botPresenceKindFromState(kind: unknown): InlineBotPresenceKind | null {
  switch (kind) {
    case BotPresenceState_Kind.IDLE:
      return "idle"
    case BotPresenceState_Kind.HAPPY:
      return "happy"
    case BotPresenceState_Kind.WAVING:
      return "waving"
    case BotPresenceState_Kind.JUMPING:
      return "jumping"
    case BotPresenceState_Kind.FAILED:
      return "failed"
    case BotPresenceState_Kind.WAITING:
      return "waiting"
    case BotPresenceState_Kind.RUNNING:
      return "running"
    case BotPresenceState_Kind.REVIEW:
      return "review"
    default:
      return null
  }
}

function normalizeInlineBotPresenceComment(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined
  const visible = sanitizeInlineVisibleText(value)
  if (visible.shouldSkip) return undefined
  const text = visible.text.replace(/\s+/g, " ").trim()
  if (!text) return undefined
  return Array.from(text).slice(0, INLINE_BOT_PRESENCE_COMMENT_MAX_LENGTH).join("")
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
      const visibleMessage = sanitizeInlineVisibleText(message)

      return await withInlineClient({
        cfg: ctx.config,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
        fn: async (client, resolvedAccountId) => {
          const result = await client.invokeRaw(Method.SEND_MESSAGE, {
            oneofKind: "sendMessage",
            sendMessage: {
              peerId: target.peerId,
              ...(!visibleMessage.shouldSkip && visibleMessage.text ? { message: visibleMessage.text } : {}),
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
            message: visibleMessage.shouldSkip || !visibleMessage.text ? null : visibleMessage.text,
            messageId,
          })
        },
      })
    },
  } as AnyAgentTool
}

function createInlineBotPresenceTool(ctx: InlineMessageToolContext): AnyAgentTool {
  return {
    name: "inline_bot_presence",
    label: "Body Cue",
    description:
      "Move or emote through your literal on-screen Inline character/body without sending a chat message. This is a cheap body-language/thought-bubble tool: use it during active work when your mood, thought, status, request, or final beat would help the human read you better.",
    parameters: InlineBotPresenceToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      if (!ctx.config) {
        throw new Error("inline_bot_presence: missing OpenClaw config")
      }

      const args = rawArgs as InlineBotPresenceToolArgs
      const action = resolveInlineBotPresenceAction(args)
      const fallbackTarget = parseCurrentInlineTarget(ctx)
      const { target, usedFallback } = resolvePeerTarget({
        label: "target",
        direct: readStringCandidate(args.to, args.target),
        chatId: args.chatId,
        userId: args.userId,
        fallback: fallbackTarget,
      })
      if (action === "get") {
        return await withInlineClient({
          cfg: ctx.config,
          accountId: args.accountId ?? ctx.agentAccountId ?? null,
          fn: async (client, resolvedAccountId) => {
            const result = await client.invokeRaw(GET_BOT_PRESENCE_METHOD, {
              oneofKind: "getBotPresence",
              getBotPresence: {
                peerId: target.peerId,
              },
            })
            if (result.oneofKind !== "getBotPresence") {
              throw new Error(`inline_bot_presence: expected getBotPresence result, got ${String(result.oneofKind)}`)
            }
            const state = result.getBotPresence.state ?? null
            return jsonResult({
              ok: true,
              action,
              accountId: resolvedAccountId,
              target: target.normalized,
              usedCurrentChatDefault: usedFallback,
              botUserId: result.getBotPresence.botUserId != null ? String(result.getBotPresence.botUserId) : null,
              avatar: result.getBotPresence.avatar ?? null,
              state,
              kind: state ? botPresenceKindFromState(state.kind) : null,
              comment: typeof state?.comment === "string" ? state.comment : null,
              peerId: result.getBotPresence.peerId ?? null,
            })
          },
        })
      }

      const kind = normalizeInlineBotPresenceKind(args.kind)
      const comment = normalizeInlineBotPresenceComment(args.comment)

      return await withInlineClient({
        cfg: ctx.config,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
        fn: async (client, resolvedAccountId) => {
          await client.invokeRaw(SET_BOT_PRESENCE_STATE_METHOD, {
            oneofKind: "setBotPresenceState",
            setBotPresenceState: {
              peerId: target.peerId,
              state: {
                kind: botPresenceStateKind(kind),
                ...(comment ? { comment } : {}),
              },
            },
          })

          return jsonResult({
            ok: true,
            action,
            accountId: resolvedAccountId,
            target: target.normalized,
            usedCurrentChatDefault: usedFallback,
            kind,
            comment: comment ?? null,
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
  return [createInlineNudgeTool(ctx), createInlineForwardTool(ctx), createInlineBotPresenceTool(ctx)]
}
