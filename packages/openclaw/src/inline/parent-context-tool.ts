import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { InlineSdkClient, Method, type Message } from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { summarizeInlineMessageContent } from "./message-content.js"
import { loadInlineReplyThreadMetadata } from "./reply-threads.js"
import {
  parseCurrentInlineSession,
  parseInlineId,
  parseInlineTarget,
  parseOptionalInlineId,
  readStringCandidate,
} from "./tool-targets.js"
import { jsonResult } from "../openclaw-compat.js"

const GET_CHAT_HISTORY_METHOD =
  typeof (Method as Record<string, unknown>).GET_CHAT_HISTORY === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_CHAT_HISTORY) &&
  ((Method as Record<string, unknown>).GET_CHAT_HISTORY as number) > 0
    ? ((Method as Record<string, unknown>).GET_CHAT_HISTORY as Method)
    : (5 as Method)

const HISTORY_MODE_LATEST = 1
const HISTORY_MODE_OLDER = 2
const HISTORY_MODE_NEWER = 3
const HISTORY_MODE_AROUND = 4

type InlineParentContextToolContext = {
  config?: OpenClawConfig
  agentAccountId?: string
  sessionKey?: string
  messageChannel?: string
}

type InlineParentContextToolArgs = {
  threadId?: string
  parentChatId?: string
  chatId?: string
  parentMessageId?: string
  anchorMessageId?: string
  beforeMessageId?: string
  afterMessageId?: string
  messageId?: string
  aroundMessageId?: string
  aroundId?: string
  mode?: string
  limit?: number
  beforeLimit?: number
  afterLimit?: number
  includeAnchor?: boolean
  accountId?: string
}

type ParentContextMode = "latest" | "older" | "newer" | "around"

type ParentHistoryInput = {
  mode: number
  limit: number
  offsetId?: bigint
  beforeId?: bigint
  afterId?: bigint
  anchorId?: bigint
  beforeLimit?: number
  afterLimit?: number
  includeAnchor?: boolean
}

const InlineParentContextToolParameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    threadId: {
      type: "string",
      description:
        "Optional Inline reply-thread chat id. Defaults to the current reply-thread chat when invoked from one.",
    },
    parentChatId: {
      type: "string",
      description: "Optional parent chat id override. Usually inferred from the current reply thread.",
    },
    chatId: {
      type: "string",
      description: "Alias for `parentChatId`.",
    },
    parentMessageId: {
      type: "string",
      description: "Optional parent/root anchor message id. Usually inferred from reply-thread metadata.",
    },
    anchorMessageId: {
      type: "string",
      description: "Alias for `parentMessageId`.",
    },
    beforeMessageId: {
      type: "string",
      description:
        "Optional message id to page older parent-chat context before. Defaults to the reply-thread anchor when known.",
    },
    afterMessageId: {
      type: "string",
      description: "Optional message id to page newer parent-chat context after.",
    },
    messageId: {
      type: "string",
      description: "Optional parent-chat message id to fetch context around.",
    },
    aroundMessageId: {
      type: "string",
      description: "Alias for `messageId` when fetching context around a parent-chat message.",
    },
    aroundId: {
      type: "string",
      description: "Alias for `messageId`.",
    },
    mode: {
      type: "string",
      enum: ["latest", "older", "newer", "around"],
      description:
        "Optional history mode. Defaults to around the reply-thread anchor when known, otherwise latest; explicit ids infer older/newer/around.",
    },
    limit: {
      type: "number",
      description: "Number of parent-chat messages to return, clamped to 1..100. Defaults to 50.",
    },
    beforeLimit: {
      type: "number",
      description: "Around mode count for messages before the anchor, clamped to 0..100.",
    },
    afterLimit: {
      type: "number",
      description: "Around mode count for messages after the anchor, clamped to 0..100.",
    },
    includeAnchor: {
      type: "boolean",
      description:
        "Whether to include the reply-thread anchor/root message when parentMessageId is known. Defaults to true.",
    },
    accountId: {
      type: "string",
      description: "Optional Inline account id override.",
    },
  },
} as const

function buildChatPeer(chatId: bigint) {
  return {
    type: {
      oneofKind: "chat" as const,
      chat: { chatId },
    },
  }
}

function readLimit(raw: unknown, fallback: number): number {
  if (raw == null) return fallback
  const value = typeof raw === "number" ? raw : typeof raw === "string" ? Number(raw.trim()) : Number.NaN
  if (!Number.isFinite(value) || !Number.isInteger(value)) {
    throw new Error("inline_parent_context: limit must be an integer")
  }
  return Math.max(1, Math.min(100, value))
}

function readWindowLimit(raw: unknown, label: string): number | undefined {
  if (raw == null) return undefined
  const value = typeof raw === "number" ? raw : typeof raw === "string" ? Number(raw.trim()) : Number.NaN
  if (!Number.isFinite(value) || !Number.isInteger(value)) {
    throw new Error(`inline_parent_context: ${label} must be an integer`)
  }
  return Math.max(0, Math.min(100, value))
}

function readMode(raw: unknown): ParentContextMode | null {
  if (raw == null) return null
  if (typeof raw !== "string") {
    throw new Error("inline_parent_context: mode must be latest, older, newer, or around")
  }
  switch (raw.trim().toLowerCase()) {
    case "":
      return null
    case "latest":
      return "latest"
    case "older":
    case "before":
      return "older"
    case "newer":
    case "after":
      return "newer"
    case "around":
      return "around"
    default:
      throw new Error("inline_parent_context: mode must be latest, older, newer, or around")
  }
}

function readIdCandidate(...values: unknown[]): unknown {
  for (const value of values) {
    if (value == null) continue
    if (typeof value === "string") {
      const trimmed = value.trim()
      if (trimmed) return trimmed
      continue
    }
    if (typeof value === "number" || typeof value === "bigint") return value
  }
  return undefined
}

function parseOptionalChatId(raw: unknown, label: string): bigint | null {
  if (raw == null) return null
  if (typeof raw === "string") {
    if (!raw.trim()) return null
    const target = parseInlineTarget(raw, label)
    if (target.peerId.type.oneofKind !== "chat") {
      throw new Error(`inline_parent_context: ${label} must be a chat target`)
    }
    return target.peerId.type.chat.chatId
  }
  return parseOptionalInlineId(raw, label)
}

function mapContextMessage(message: Message, anchorMessageId: bigint | null) {
  const content = summarizeInlineMessageContent(message)
  return {
    id: String(message.id),
    fromId: String(message.fromId),
    date: Number(message.date) * 1000,
    text: content.text,
    rawText: content.rawText,
    attachmentText: content.attachmentText,
    entityText: content.entityText,
    out: Boolean(message.out),
    replyToId: message.replyToMsgId != null ? String(message.replyToMsgId) : undefined,
    isAnchor: anchorMessageId != null && message.id === anchorMessageId,
    attachmentUrls: content.attachmentUrls,
    links: content.links,
    media: content.media,
    attachments: content.attachments,
    entities: content.entities,
  }
}

function sortMessages(messages: Message[]): Message[] {
  return messages.slice().sort((a, b) => {
    const byDate = Number(a.date - b.date)
    if (byDate !== 0) return byDate
    if (a.id === b.id) return 0
    return a.id < b.id ? -1 : 1
  })
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

async function loadParentHistory(params: {
  client: InlineSdkClient
  parentChatId: bigint
  input: ParentHistoryInput
}): Promise<Message[]> {
  if (params.input.limit <= 0) return []
  const result = await params.client.invokeRaw(GET_CHAT_HISTORY_METHOD, {
    oneofKind: "getChatHistory",
    getChatHistory: {
      peerId: buildChatPeer(params.parentChatId),
      ...params.input,
    },
  })
  if (result.oneofKind !== "getChatHistory") {
    throw new Error(
      `inline_parent_context: expected getChatHistory result, got ${String(result.oneofKind)}`,
    )
  }
  return result.getChatHistory.messages ?? []
}

function resolveParentContextHistoryRequest(params: {
  parentMessageId: bigint | null
  beforeMessageId: bigint | null
  afterMessageId: bigint | null
  aroundMessageId: bigint | null
  explicitMode: ParentContextMode | null
  includeAnchor: boolean
  limit: number
  beforeLimit?: number
  afterLimit?: number
}): {
  mode: ParentContextMode
  input: ParentHistoryInput
  anchorMessageId: bigint | null
  beforeMessageId: bigint | null
  afterMessageId: bigint | null
  beforeLimit: number | null
  afterLimit: number | null
} {
  if (params.aroundMessageId != null && (params.beforeMessageId != null || params.afterMessageId != null)) {
    throw new Error("inline_parent_context: messageId/aroundMessageId cannot be combined with before or after")
  }
  if (params.beforeMessageId != null && params.afterMessageId != null) {
    throw new Error("inline_parent_context: pass only one of beforeMessageId or afterMessageId")
  }

  const mode =
    params.explicitMode ??
    (params.aroundMessageId != null
      ? "around"
      : params.afterMessageId != null
        ? "newer"
        : params.beforeMessageId != null
          ? "older"
          : params.parentMessageId != null
            ? "around"
            : "latest")

  if (mode !== "around" && (params.beforeLimit !== undefined || params.afterLimit !== undefined)) {
    throw new Error("inline_parent_context: beforeLimit and afterLimit are only valid with around mode")
  }

  if (mode === "latest") {
    if (params.aroundMessageId != null || params.beforeMessageId != null || params.afterMessageId != null) {
      throw new Error("inline_parent_context: latest mode cannot be combined with message cursors")
    }
    return {
      mode,
      input: {
        mode: HISTORY_MODE_LATEST,
        limit: params.limit,
      },
      anchorMessageId: null,
      beforeMessageId: null,
      afterMessageId: null,
      beforeLimit: null,
      afterLimit: null,
    }
  }

  if (mode === "newer") {
    if (params.afterMessageId == null) {
      throw new Error("inline_parent_context: newer mode requires afterMessageId")
    }
    return {
      mode,
      input: {
        mode: HISTORY_MODE_NEWER,
        afterId: params.afterMessageId,
        limit: params.limit,
      },
      anchorMessageId: null,
      beforeMessageId: null,
      afterMessageId: params.afterMessageId,
      beforeLimit: null,
      afterLimit: null,
    }
  }

  if (mode === "older") {
    const beforeMessageId = params.beforeMessageId ?? params.parentMessageId
    if (beforeMessageId == null) {
      throw new Error("inline_parent_context: older mode requires beforeMessageId outside a known reply thread")
    }
    return {
      mode,
      input: {
        mode: HISTORY_MODE_OLDER,
        beforeId: beforeMessageId,
        offsetId: beforeMessageId,
        limit: params.limit,
      },
      anchorMessageId: null,
      beforeMessageId,
      afterMessageId: null,
      beforeLimit: null,
      afterLimit: null,
    }
  }

  const anchorMessageId = params.aroundMessageId ?? params.parentMessageId
  if (anchorMessageId == null) {
    throw new Error("inline_parent_context: around mode requires messageId outside a known reply thread")
  }
  const defaultBeforeLimit =
    params.aroundMessageId == null && params.parentMessageId != null
      ? Math.max(0, params.limit - (params.includeAnchor ? 1 : 0))
      : undefined
  const defaultAfterLimit =
    params.aroundMessageId == null && params.parentMessageId != null ? 0 : undefined
  const beforeLimit = params.beforeLimit ?? defaultBeforeLimit
  const afterLimit = params.afterLimit ?? defaultAfterLimit

  return {
    mode,
    input: {
      mode: HISTORY_MODE_AROUND,
      anchorId: anchorMessageId,
      limit: params.limit,
      ...(beforeLimit !== undefined ? { beforeLimit } : {}),
      ...(afterLimit !== undefined ? { afterLimit } : {}),
      includeAnchor: params.includeAnchor,
    },
    anchorMessageId,
    beforeMessageId: null,
    afterMessageId: null,
    beforeLimit: beforeLimit ?? null,
    afterLimit: afterLimit ?? null,
  }
}

export function createInlineParentContextTool(ctx: InlineParentContextToolContext): AnyAgentTool | null {
  if (!ctx.config) return null

  return {
    name: "inline_parent_context",
    label: "Inline Parent Context",
    description:
      "Fetch additional parent-chat messages for the current Inline reply thread. Use this when the thread's built-in parent context is not enough to answer from the discussion that happened before the thread anchor.",
    parameters: InlineParentContextToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      const args = rawArgs as InlineParentContextToolArgs
      const currentSession = parseCurrentInlineSession(ctx)
      const explicitThreadId = readStringCandidate(args.threadId)
      const threadId =
        explicitThreadId != null
          ? parseInlineId(explicitThreadId, "threadId")
          : currentSession?.threadId ?? null
      let parentChatId =
        parseOptionalChatId(readIdCandidate(args.parentChatId, args.chatId), "parentChatId") ??
        currentSession?.parentChatId ??
        null
      let parentMessageId =
        parseOptionalInlineId(
          readIdCandidate(args.parentMessageId, args.anchorMessageId),
          "parentMessageId",
        )
      const beforeMessageId = parseOptionalInlineId(readIdCandidate(args.beforeMessageId), "beforeMessageId")
      const afterMessageId = parseOptionalInlineId(readIdCandidate(args.afterMessageId), "afterMessageId")
      const aroundMessageId = parseOptionalInlineId(
        readIdCandidate(args.messageId, args.aroundMessageId, args.aroundId),
        "messageId",
      )
      const explicitMode = readMode(args.mode)
      const limit = readLimit(args.limit, 50)
      const beforeLimit = readWindowLimit(args.beforeLimit, "beforeLimit")
      const afterLimit = readWindowLimit(args.afterLimit, "afterLimit")
      const includeAnchor = args.includeAnchor !== false

      return await withInlineClient({
        cfg: ctx.config as OpenClawConfig,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
        fn: async (client, resolvedAccountId) => {
          let threadTitle: string | null = null
          if (threadId != null) {
            const metadata = await loadInlineReplyThreadMetadata({ client, chatId: threadId })
            parentChatId = metadata?.parentChatId ?? parentChatId
            parentMessageId = parentMessageId ?? metadata?.parentMessageId ?? null
            threadTitle = metadata?.title ?? null
          }

          if (parentChatId == null) {
            throw new Error("inline_parent_context: parentChatId is required outside an Inline reply-thread session")
          }

          const history = resolveParentContextHistoryRequest({
            parentMessageId,
            beforeMessageId,
            afterMessageId,
            aroundMessageId,
            explicitMode,
            includeAnchor,
            limit,
            ...(beforeLimit !== undefined ? { beforeLimit } : {}),
            ...(afterLimit !== undefined ? { afterLimit } : {}),
          })
          const messages = sortMessages(
            await loadParentHistory({
              client,
              parentChatId,
              input: history.input,
            }),
          ).map((message) => mapContextMessage(message, history.anchorMessageId))
          const oldest = messages[0]
          const newest = messages[messages.length - 1]

          return jsonResult({
            ok: true,
            accountId: resolvedAccountId,
            parentChatId: String(parentChatId),
            threadId: threadId != null ? String(threadId) : null,
            threadTitle,
            parentMessageId: parentMessageId != null ? String(parentMessageId) : null,
            mode: history.mode,
            beforeMessageId: history.beforeMessageId != null ? String(history.beforeMessageId) : null,
            afterMessageId: history.afterMessageId != null ? String(history.afterMessageId) : null,
            aroundMessageId: history.anchorMessageId != null ? String(history.anchorMessageId) : null,
            beforeLimit: history.beforeLimit,
            afterLimit: history.afterLimit,
            limit,
            includeAnchor,
            usedCurrentThreadDefault: explicitThreadId == null && currentSession?.threadId != null,
            nextBeforeMessageId: oldest?.id ?? null,
            nextAfterMessageId: newest?.id ?? null,
            messages,
          })
        },
      })
    },
  } as AnyAgentTool
}
