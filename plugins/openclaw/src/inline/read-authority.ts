import * as fetchRuntime from "openclaw/plugin-sdk/fetch-runtime"
import { normalizeInlineTarget } from "./normalize.js"

/**
 * Host fence for provider-owned reads. Call immediately before every Inline
 * request (connect, target lookups, history) made for one read invocation.
 * A throw stops that request; never retry with a freshly captured fence.
 */
export type InlineReadFence = () => void

type CaptureChannelReadAuthority = () => (() => void) | undefined

function resolveCaptureChannelReadAuthority(): CaptureChannelReadAuthority | undefined {
  // Read the export dynamically: hosts before the read-authority contract
  // ship fetch-runtime without it, and a named import would fail to link.
  const runtime: Record<string, unknown> = fetchRuntime
  const capture = runtime["captureChannelReadAuthority"]
  return typeof capture === "function" ? (capture as CaptureChannelReadAuthority) : undefined
}

/** Capture at request submission, inside the host's read-authority scope. */
export function captureInlineReadFence(params: {
  assertDirectAdapterHandoff?: (() => void) | undefined
}): InlineReadFence {
  const readAuthority = resolveCaptureChannelReadAuthority()?.()
  const handoff = params.assertDirectAdapterHandoff
  return () => {
    readAuthority?.()
    handoff?.()
  }
}

type InlineChatPeer =
  | { type: { oneofKind: "user"; user: { userId: bigint } } }
  | { type: { oneofKind: "chat"; chat: { chatId: bigint } } }
  | { type: { oneofKind: undefined } }

type InlineChatLookup = {
  chatId: bigint
  peer?: unknown
  spaceId?: bigint
  parentChatId?: bigint
  isPublic?: boolean
}

export type InlineReadGuardClient = {
  getChat(params: { chatId: bigint }): Promise<InlineChatLookup>
  /** User ids with a direct or group grant on this chat (getChatParticipants). */
  listChatParticipantIds(params: { chatId: bigint }): Promise<readonly bigint[]>
}

/** Where a chat lives: its space, or the top-level chat its threads hang off. */
type InlineChatScope = {
  chatId: bigint
  spaceId: bigint | null
  parentChatId: bigint | null
  rootChatId: bigint
  /** Public space chat: every space member can read it and its threads. */
  rootIsPublic: boolean
  /** Set when the root chat is the bot's DM with this user. */
  rootDmUserId: bigint | null
}

export type InlineReadGuardParams = {
  client: InlineReadGuardClient
  fence: InlineReadFence
  /** Read target: a chat or thread id, or a user id for that user's DM. */
  target: { kind: "chat"; chatId: bigint } | { kind: "user"; userId: bigint }
  toolContext?:
    | {
        currentChannelId?: string | number | null | undefined
        currentThreadTs?: string | number | null | undefined
        currentChannelProvider?: string | null | undefined
      }
    | undefined
  requesterSenderId?: string | null | undefined
  conversationReadOrigin?: string | null | undefined
}

/** null when absent; throws when present but not an Inline chat id. */
function parseContextId(value: string | number | null | undefined): bigint | null {
  if (value == null) return null
  if (typeof value === "number") {
    if (Number.isSafeInteger(value) && value > 0) return BigInt(value)
  } else {
    if (!value.trim()) return null
    const normalized = normalizeInlineTarget(value)
    if (normalized && /^[0-9]+$/.test(normalized)) return BigInt(normalized)
  }
  return deny("needs an Inline chat id for the current conversation")
}

function dmUserIdFromPeer(peer: unknown): bigint | null {
  const type = (peer as InlineChatPeer | undefined)?.type
  return type?.oneofKind === "user" ? type.user.userId : null
}

async function loadChat(
  params: Pick<InlineReadGuardParams, "client" | "fence">,
  chatId: bigint,
): Promise<InlineChatLookup> {
  params.fence()
  return await params.client.getChat({ chatId })
}

async function loadChatScope(
  params: Pick<InlineReadGuardParams, "client" | "fence">,
  chatId: bigint,
): Promise<InlineChatScope> {
  const chat = await loadChat(params, chatId)
  if (chat.parentChatId == null) {
    return {
      chatId: chat.chatId,
      spaceId: chat.spaceId ?? null,
      parentChatId: null,
      rootChatId: chat.chatId,
      rootIsPublic: chat.spaceId != null && chat.isPublic === true,
      rootDmUserId: chat.spaceId == null ? dmUserIdFromPeer(chat.peer) : null,
    }
  }
  const parent = await loadChat(params, chat.parentChatId)
  const spaceId = chat.spaceId ?? parent.spaceId ?? null
  return {
    chatId: chat.chatId,
    spaceId,
    parentChatId: parent.chatId,
    rootChatId: parent.chatId,
    rootIsPublic: spaceId != null && parent.isPublic === true,
    rootDmUserId: spaceId == null ? dmUserIdFromPeer(parent.peer) : null,
  }
}

async function hasParticipant(
  params: Pick<InlineReadGuardParams, "client" | "fence">,
  chatId: bigint,
  userId: bigint,
): Promise<boolean> {
  params.fence()
  const ids = await params.client.listChatParticipantIds({ chatId })
  return ids.includes(userId)
}

/**
 * Mirrors the server's chat access for the asker, not the bot: a direct or
 * group grant on the chat, or for a thread, on its parent. Public space chats
 * are open to the space, which the asker shares through the current chat.
 */
async function isTargetMember(
  params: Pick<InlineReadGuardParams, "client" | "fence">,
  target: InlineChatScope,
  userId: bigint,
): Promise<boolean> {
  if (target.rootIsPublic) return true
  if (await hasParticipant(params, target.chatId, userId)) return true
  return target.parentChatId != null && (await hasParticipant(params, target.parentChatId, userId))
}

function deny(reason: string): never {
  throw new Error(`inline action: read ${reason}`)
}

/**
 * Provider-owned admission for `read` once the host delegates it.
 *
 * Reads from inside an Inline conversation may target that conversation, or
 * another chat/thread in the same space or under the same parent chat that
 * the asker can access too. Any chat rooted in a DM (the DM itself or a
 * thread under it) is readable only by that DM's user, so people added to a
 * DM's thread can't reach the DM.
 * Direct operators and context-free host turns keep host admission alone.
 */
export async function assertInlineReadAllowed(params: InlineReadGuardParams): Promise<void> {
  if (params.conversationReadOrigin === "direct-operator") return

  const context = params.toolContext
  const provider = context?.currentChannelProvider?.trim().toLowerCase()
  if (provider && provider !== "inline") {
    deny("from another channel's conversation is not allowed")
  }
  const currentChatId = parseContextId(context?.currentChannelId)
  const currentThreadId = parseContextId(context?.currentThreadTs)
  const currentConversationId = currentThreadId ?? currentChatId
  if (currentConversationId == null) return

  if (params.target.kind === "chat" && params.target.chatId === currentConversationId) return

  const requester = params.requesterSenderId?.trim() || null
  if (params.target.kind === "user" && requester !== String(params.target.userId)) {
    deny("of another person's DM is not allowed")
  }
  const current = await loadChatScope(params, currentConversationId)

  if (params.target.kind === "user") {
    const userId = params.target.userId
    if (current.rootDmUserId !== userId) {
      deny("of a DM is allowed only from that DM or its threads")
    }
    return
  }

  const target = await loadChatScope(params, params.target.chatId)
  if (target.rootDmUserId != null && requester !== String(target.rootDmUserId)) {
    deny("of a DM or its threads is allowed only for that DM's user")
  }
  const sameSpace = target.spaceId != null && target.spaceId === current.spaceId
  const sameRoot = target.rootChatId === current.rootChatId
  if (!sameSpace && !sameRoot) {
    deny("is limited to chats in the current space or under the current parent chat")
  }
  // DM-rooted targets already require the DM's own user, who always has access.
  if (target.rootDmUserId != null) return
  if (requester == null || !/^[0-9]+$/.test(requester)) {
    deny("of another chat needs the asking Inline user")
  }
  if (!(await isTargetMember(params, target, BigInt(requester)))) {
    deny("of a chat the asker isn't a participant of is not allowed")
  }
}
