import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { InlineSdkClient, Method, type Message } from "@inline-chat/realtime-sdk"

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

function inlineErrorChainHasCode(error: unknown, code: string): boolean {
  const visited = new Set<unknown>()
  let current: unknown = error
  while (current && typeof current === "object" && !visited.has(current)) {
    visited.add(current)
    if ((current as { code?: unknown }).code === code) return true
    current = (current as { cause?: unknown }).cause
  }
  return false
}

function isRetryableInlineCreateOutcomeUnknown(error: unknown): boolean {
  return inlineErrorChainHasCode(error, "commit-outcome-unknown") ||
    inlineErrorChainHasCode(error, "timeout")
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
  void params
  return { replyThreads: true }
}

export function isInlineReplyThreadsEnabled(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): boolean {
  void params
  return getInlineReplyThreadsCapabilityConfig(params).replyThreads
}

export function resolveInlineReplyThreadChatId(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  parentChatId: bigint | null
  threadId?: string | number | null
}): bigint | null {
  void params.cfg
  void params.accountId
  if (params.parentChatId == null) {
    return null
  }
  if (params.threadId == null) {
    return params.parentChatId
  }

  const normalized =
    typeof params.threadId === "number"
      ? Number.isSafeInteger(params.threadId) && params.threadId > 0
        ? BigInt(params.threadId)
        : null
      : typeof params.threadId === "string"
        ? /^[0-9]+$/.test(params.threadId.trim())
          ? (() => {
              try {
                return BigInt(params.threadId.trim())
              } catch {
                return null
              }
            })()
          : null
        : null

  if (normalized == null || normalized <= 0n) {
    throw new Error("inline: invalid reply-thread chat id")
  }
  return normalized
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
  const input = {
    oneofKind: "createSubthread" as const,
    createSubthread: {
      parentChatId: params.parentChatId,
      parentMessageId: params.parentMessageId,
      participants: [],
    },
  }
  const invokeCreate = () => params.client.invokeRaw(CREATE_SUBTHREAD_METHOD, input)
  let result: Awaited<ReturnType<typeof invokeCreate>>
  try {
    result = await invokeCreate()
  } catch (error) {
    if (!isRetryableInlineCreateOutcomeUnknown(error)) throw error
    // Reply-thread creation is idempotent for this exact parent-message anchor.
    // A single retry recovers the server result when the first response was
    // lost after commit without risking a second child.
    result = await invokeCreate()
  }

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
