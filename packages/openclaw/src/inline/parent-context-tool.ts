import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { InlineSdkClient, Method, type Message } from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { summarizeInlineMessageContent } from "./message-content.js"
import {
  loadInlineReplyThreadAnchorMessage,
  loadInlineReplyThreadMetadata,
} from "./reply-threads.js"
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
  limit?: number
  includeAnchor?: boolean
  accountId?: string
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
    limit: {
      type: "number",
      description: "Number of parent-chat messages to return, clamped to 1..100. Defaults to 50.",
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

function mapContextMessage(message: Message, parentMessageId: bigint | null) {
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
    isAnchor: parentMessageId != null && message.id === parentMessageId,
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

function messageDedupeKey(message: Message): string {
  return `${String(message.id)}:${String(message.date)}`
}

function dedupeMessages(messages: Message[]): Message[] {
  const seen = new Set<string>()
  const out: Message[] = []
  for (const message of messages) {
    const key = messageDedupeKey(message)
    if (seen.has(key)) continue
    seen.add(key)
    out.push(message)
  }
  return out
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
  offsetId: bigint | null
  limit: number
}): Promise<Message[]> {
  if (params.limit <= 0) return []
  const result = await params.client.invokeRaw(GET_CHAT_HISTORY_METHOD, {
    oneofKind: "getChatHistory",
    getChatHistory: {
      peerId: buildChatPeer(params.parentChatId),
      ...(params.offsetId != null ? { offsetId: params.offsetId } : {}),
      limit: params.limit,
    },
  })
  if (result.oneofKind !== "getChatHistory") {
    throw new Error(
      `inline_parent_context: expected getChatHistory result, got ${String(result.oneofKind)}`,
    )
  }
  return result.getChatHistory.messages ?? []
}

async function loadParentContextMessages(params: {
  client: InlineSdkClient
  parentChatId: bigint
  parentMessageId: bigint | null
  beforeMessageId: bigint | null
  includeAnchor: boolean
  limit: number
}): Promise<Message[]> {
  if (params.beforeMessageId != null) {
    return sortMessages(
      await loadParentHistory({
        client: params.client,
        parentChatId: params.parentChatId,
        offsetId: params.beforeMessageId,
        limit: params.limit,
      }),
    )
  }

  if (params.parentMessageId == null) {
    return sortMessages(
      await loadParentHistory({
        client: params.client,
        parentChatId: params.parentChatId,
        offsetId: null,
        limit: params.limit,
      }),
    )
  }

  const anchor =
    params.includeAnchor
      ? await loadInlineReplyThreadAnchorMessage({
          client: params.client,
          parentChatId: params.parentChatId,
          parentMessageId: params.parentMessageId,
        })
      : null
  const historyLimit = Math.max(0, params.limit - (anchor ? 1 : 0))
  const history = await loadParentHistory({
    client: params.client,
    parentChatId: params.parentChatId,
    offsetId: params.parentMessageId,
    limit: historyLimit,
  })
  return sortMessages(dedupeMessages([...history, ...(anchor ? [anchor] : [])]))
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
      const limit = readLimit(args.limit, 50)
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

          const messages = (
            await loadParentContextMessages({
              client,
              parentChatId,
              parentMessageId,
              beforeMessageId,
              includeAnchor,
              limit,
            })
          ).map((message) => mapContextMessage(message, parentMessageId))
          const oldest = messages[0]

          return jsonResult({
            ok: true,
            accountId: resolvedAccountId,
            parentChatId: String(parentChatId),
            threadId: threadId != null ? String(threadId) : null,
            threadTitle,
            parentMessageId: parentMessageId != null ? String(parentMessageId) : null,
            limit,
            includeAnchor,
            usedCurrentThreadDefault: explicitThreadId == null && currentSession?.threadId != null,
            nextBeforeMessageId: oldest?.id ?? null,
            messages,
          })
        },
      })
    },
  } as AnyAgentTool
}
