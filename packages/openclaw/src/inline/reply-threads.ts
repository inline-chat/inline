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

export type InlineReplyThreadMetadata = {
  childChatId: bigint
  parentChatId: bigint
  parentMessageId: bigint | null
  title: string | null
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
    replyThreads: account.config.capabilities?.replyThreads === true,
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
