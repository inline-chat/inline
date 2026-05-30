import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { InlineSdkClient, Method, type Message } from "@inline-chat/realtime-sdk"
import { resolveInlineAccount } from "./accounts.js"

const GET_CHAT_METHOD =
  typeof (Method as Record<string, unknown>).GET_CHAT === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_CHAT) &&
  ((Method as Record<string, unknown>).GET_CHAT as number) > 0
    ? ((Method as Record<string, unknown>).GET_CHAT as Method)
    : (25 as Method)

const GET_CHAT_HISTORY_METHOD =
  typeof (Method as Record<string, unknown>).GET_CHAT_HISTORY === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_CHAT_HISTORY) &&
  ((Method as Record<string, unknown>).GET_CHAT_HISTORY as number) > 0
    ? ((Method as Record<string, unknown>).GET_CHAT_HISTORY as Method)
    : (5 as Method)

const GET_MESSAGES_METHOD =
  typeof (Method as Record<string, unknown>).GET_MESSAGES === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_MESSAGES) &&
  ((Method as Record<string, unknown>).GET_MESSAGES as number) > 0
    ? ((Method as Record<string, unknown>).GET_MESSAGES as Method)
    : (38 as Method)

const CREATE_SUBTHREAD_METHOD =
  typeof (Method as Record<string, unknown>).CREATE_SUBTHREAD === "number" &&
  Number.isInteger((Method as Record<string, unknown>).CREATE_SUBTHREAD) &&
  ((Method as Record<string, unknown>).CREATE_SUBTHREAD as number) > 0
    ? ((Method as Record<string, unknown>).CREATE_SUBTHREAD as Method)
    : (42 as Method)

export type InlineReplyThreadMetadata = {
  childChatId: bigint
  parentChatId: bigint
  parentMessageId: bigint | null
  title: string | null
}

export type InlineCreatedReplyThread = {
  childChatId: bigint
  parentChatId: bigint
  parentMessageId: bigint
  title: string | null
  anchorMessage: Message | null
}

function isPlacementMode(raw: unknown): boolean {
  return raw === "thread" || raw === "main"
}

function hasReplyThreadPlacementConfig(config: { replyThreadMode?: unknown; groups?: unknown }): boolean {
  if (isPlacementMode(config.replyThreadMode)) return true
  if (!config.groups || typeof config.groups !== "object" || Array.isArray(config.groups)) return false

  return Object.values(config.groups).some((group) => {
    if (!group || typeof group !== "object" || Array.isArray(group)) return false
    return isPlacementMode((group as { replyThreadMode?: unknown }).replyThreadMode)
  })
}

function buildChatPeer(chatId: bigint): {
  type: {
    oneofKind: "chat"
    chat: { chatId: bigint }
  }
} {
  return {
    type: {
      oneofKind: "chat",
      chat: { chatId },
    },
  }
}

export function getInlineReplyThreadsCapabilityConfig(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): { replyThreads: boolean } {
  const account = resolveInlineAccount({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
  })

  return {
    replyThreads:
      account.config.capabilities?.replyThreads === true ||
      hasReplyThreadPlacementConfig(account.config),
  }
}

export function isInlineReplyThreadsEnabled(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): boolean {
  return getInlineReplyThreadsCapabilityConfig(params).replyThreads
}

export function resolveInlineReplyThreadChatId(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  parentChatId: bigint | null
  threadId?: string | number | null
}): bigint | null {
  if (!isInlineReplyThreadsEnabled({ cfg: params.cfg, accountId: params.accountId ?? null })) {
    return params.parentChatId
  }
  if (params.parentChatId == null) {
    return null
  }
  if (params.threadId == null) {
    return params.parentChatId
  }

  const normalized =
    typeof params.threadId === "number"
      ? Number.isFinite(params.threadId) && Number.isInteger(params.threadId) && params.threadId >= 0
        ? BigInt(params.threadId)
        : null
      : typeof params.threadId === "string"
        ? params.threadId.trim()
          ? (() => {
              try {
                return BigInt(params.threadId.trim())
              } catch {
                return null
              }
            })()
          : null
        : null

  return normalized ?? params.parentChatId
}

export async function loadInlineReplyThreadMetadata(params: {
  client: InlineSdkClient
  chatId: bigint
}): Promise<InlineReplyThreadMetadata | null> {
  const result = await params.client
    .invokeRaw(GET_CHAT_METHOD, {
      oneofKind: "getChat",
      getChat: { peerId: buildChatPeer(params.chatId) },
    })
    .catch(() => null)

  if (result?.oneofKind !== "getChat") {
    return null
  }

  const chat = result.getChat.chat
  const parentChatId = chat?.parentChatId
  if (parentChatId == null) {
    return null
  }

  return {
    childChatId: chat?.id ?? params.chatId,
    parentChatId,
    parentMessageId: chat?.parentMessageId ?? null,
    title: chat?.title?.trim() || null,
  }
}

export async function loadInlineReplyThreadAnchorMessage(params: {
  client: InlineSdkClient
  parentChatId: bigint
  parentMessageId: bigint
}): Promise<Message | null> {
  const directResult = await params.client
    .invokeRaw(GET_MESSAGES_METHOD, {
      oneofKind: "getMessages",
      getMessages: {
        peerId: buildChatPeer(params.parentChatId),
        messageIds: [params.parentMessageId],
      },
    })
    .catch(() => null)

  if (directResult?.oneofKind === "getMessages") {
    const directTarget =
      (directResult.getMessages.messages ?? []).find((item) => item.id === params.parentMessageId) ?? null
    if (directTarget) {
      return directTarget
    }
  }

  const historyResult = await params.client
    .invokeRaw(GET_CHAT_HISTORY_METHOD, {
      oneofKind: "getChatHistory",
      getChatHistory: {
        peerId: buildChatPeer(params.parentChatId),
        offsetId: params.parentMessageId + 1n,
        limit: 8,
      },
    })
    .catch(() => null)

  if (historyResult?.oneofKind !== "getChatHistory") {
    return null
  }

  return (historyResult.getChatHistory.messages ?? []).find((item) => item.id === params.parentMessageId) ?? null
}

export async function createInlineReplyThreadForMessage(params: {
  client: InlineSdkClient
  parentChatId: bigint
  parentMessageId: bigint
}): Promise<InlineCreatedReplyThread | null> {
  const result = await params.client.invokeRaw(CREATE_SUBTHREAD_METHOD, {
    oneofKind: "createSubthread",
    createSubthread: {
      parentChatId: params.parentChatId,
      parentMessageId: params.parentMessageId,
      participants: [],
    },
  })

  if (result.oneofKind !== "createSubthread") {
    return null
  }

  const chat = result.createSubthread.chat
  if (!chat?.id) {
    return null
  }

  return {
    childChatId: chat.id,
    parentChatId: chat.parentChatId ?? params.parentChatId,
    parentMessageId: chat.parentMessageId ?? params.parentMessageId,
    title: chat.title?.trim() || null,
    anchorMessage: result.createSubthread.anchorMessage ?? null,
  }
}
