import type { InputPeer, MessageEntities } from "@inline-chat/protocol/core"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { CHATGPT_AGENT_KEY } from "@inline-chat/agent-chatgpt"
import type { DbChat, DbMessage } from "@in/server/db/schema"
import { MessageModel } from "@in/server/db/models/messages"
import { extractMentionCandidates } from "@in/server/modules/message/processOutgoingText"
import { resolveInternalAgentAlias } from "@in/server/modules/internalAgents/aliases"

export type ChatgptTrigger =
  | {
      readonly kind: "message"
      readonly reason: "dm" | "mention" | "reply" | "thread"
      readonly runKey: string
      readonly inputPeer: InputPeer
      readonly threadRootMsgId: number | null
      readonly alias?: string
    }
  | {
      readonly kind: "stop"
      readonly runKey: string
      readonly inputPeer: InputPeer
      readonly threadRootMsgId: number | null
    }

export async function detectChatgptTrigger(input: {
  readonly chat: DbChat
  readonly message: DbMessage
  readonly text?: string
  readonly entities?: MessageEntities
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly lookups?: ChatgptTriggerLookups
}): Promise<ChatgptTrigger | undefined> {
  if (input.message.fromId === input.botUserId) {
    return undefined
  }

  const threadRootMsgId = input.chat.parentMessageId ?? null
  const runKey = buildChatgptRunKey({
    chatId: input.chat.id,
    threadRootMsgId,
    actorUserId: input.actorUserId,
  })

  const isDm = input.chat.type === "private" && input.chat.minUserId === Math.min(input.actorUserId, input.botUserId) && input.chat.maxUserId === Math.max(input.actorUserId, input.botUserId)
  const replyToBot = input.message.replyToMsgId
    ? await (input.lookups?.isReplyToBot ?? isReplyToBot)({
        chatId: input.chat.id,
        messageId: input.message.replyToMsgId,
        botUserId: input.botUserId,
      })
    : false
  const threadRootFromBot = await (input.lookups?.isThreadRootFromBot ?? isThreadRootFromBot)({
    chat: input.chat,
    botUserId: input.botUserId,
  })

  if (isStopCommand(input.text, input.entities, replyToBot || isDm || threadRootFromBot)) {
    return { kind: "stop", runKey, inputPeer: input.inputPeer, threadRootMsgId }
  }

  if (isDm) {
    return { kind: "message", reason: "dm", runKey, inputPeer: input.inputPeer, threadRootMsgId }
  }

  const alias = findAliasMention(input.text, input.entities)
  if (alias) {
    return { kind: "message", reason: "mention", runKey, inputPeer: input.inputPeer, threadRootMsgId, alias }
  }

  if (replyToBot) {
    return { kind: "message", reason: "reply", runKey, inputPeer: input.inputPeer, threadRootMsgId }
  }

  if (threadRootFromBot) {
    return { kind: "message", reason: "thread", runKey, inputPeer: input.inputPeer, threadRootMsgId }
  }

  return undefined
}

type ChatgptTriggerLookups = {
  readonly isReplyToBot?: (input: { readonly chatId: number; readonly messageId: number; readonly botUserId: number }) => Promise<boolean>
  readonly isThreadRootFromBot?: (input: { readonly chat: DbChat; readonly botUserId: number }) => Promise<boolean>
}

export function buildChatgptRunKey(input: {
  readonly chatId: number
  readonly threadRootMsgId?: number | null
  readonly actorUserId: number
}): string {
  return `chatgpt:${input.chatId}:${input.threadRootMsgId ?? "main"}:${input.actorUserId}`
}

function findAliasMention(text: string | undefined, entities: MessageEntities | undefined): string | undefined {
  for (const candidate of extractMentionCandidates(text ?? "")) {
    const registration = resolveInternalAgentAlias(candidate.username)
    if (registration?.agentKey === CHATGPT_AGENT_KEY) {
      return candidate.username.toLowerCase()
    }
  }

  for (const entity of entities?.entities ?? []) {
    if (entity?.type !== MessageEntity_Type.MENTION || entity.entity.oneofKind !== "mention") {
      continue
    }
    // Canonical @chatgpt resolves to the real user row; aliases without rows are handled above.
    const registration = resolveInternalAgentAlias(entityText(text ?? "", entity.offset, entity.length))
    if (registration?.agentKey === CHATGPT_AGENT_KEY) {
      return registration.botUsername
    }
  }

  return undefined
}

function isStopCommand(text: string | undefined, entities: MessageEntities | undefined, allowBare: boolean): boolean {
  const trimmed = text?.trim().toLowerCase()
  if (!trimmed) {
    return false
  }

  if (allowBare && trimmed === "/stop") {
    return true
  }

  const match = trimmed.match(/^\/stop@([a-z0-9_]+)$/)
  if (match?.[1] && resolveInternalAgentAlias(match[1])?.agentKey === CHATGPT_AGENT_KEY) {
    return true
  }

  for (const entity of entities?.entities ?? []) {
    if (entity?.type !== MessageEntity_Type.BOT_COMMAND) {
      continue
    }
    const command = entityText(text ?? "", entity.offset, entity.length).toLowerCase()
    if (command === "/stop" && allowBare) {
      return true
    }
    const suffix = command.match(/^\/stop@([a-z0-9_]+)$/)
    if (suffix?.[1] && resolveInternalAgentAlias(suffix[1])?.agentKey === CHATGPT_AGENT_KEY) {
      return true
    }
  }

  return false
}

async function isReplyToBot(input: {
  readonly chatId: number
  readonly messageId: number
  readonly botUserId: number
}): Promise<boolean> {
  try {
    const replied = await MessageModel.getMessage(input.messageId, input.chatId)
    return replied.fromId === input.botUserId
  } catch {
    return false
  }
}

async function isThreadRootFromBot(input: {
  readonly chat: DbChat
  readonly botUserId: number
}): Promise<boolean> {
  if (input.chat.parentChatId == null || input.chat.parentMessageId == null) {
    return false
  }

  try {
    const root = await MessageModel.getMessage(input.chat.parentMessageId, input.chat.parentChatId)
    return root.fromId === input.botUserId
  } catch {
    return false
  }
}

function entityText(text: string, offset: bigint, length: bigint): string {
  const start = Number(offset)
  const end = start + Number(length)
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end > text.length) {
    return ""
  }
  return text.slice(start, end).replace(/^@/, "")
}
