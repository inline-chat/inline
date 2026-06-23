import type { AgentPromptMessage, AgentPromptPart } from "@inline-chat/agent-core"
import { textPart } from "@inline-chat/agent-core"
import { MessageModel, type DbFullMessage } from "@in/server/db/models/messages"
import type { InputPeer } from "@inline-chat/protocol/core"
import { attachmentContextText, buildAttachmentPromptParts } from "@in/server/modules/chatgpt/harness/media/attachments"

const HISTORY_LIMIT = 28

export async function loadPromptHistory(input: {
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly triggerMessageId: number
}): Promise<{ readonly messages: readonly DbFullMessage[]; readonly prompt: readonly AgentPromptMessage[] }> {
  const messages = await MessageModel.getMessages(input.inputPeer, {
    currentUserId: input.actorUserId,
    mode: "older",
    beforeId: BigInt(input.triggerMessageId + 1),
    limit: HISTORY_LIMIT,
  })

  const ordered = [...messages].sort((a, b) => a.messageId - b.messageId)
  return {
    messages: ordered,
    prompt: ordered.map((message) => messageToPrompt(message, input.botUserId)),
  }
}

function messageToPrompt(message: DbFullMessage, botUserId: number): AgentPromptMessage {
  const role = message.fromId === botUserId ? "assistant" : "user"
  const display = message.from?.firstName || message.from?.username || `user ${message.fromId}`
  const text = message.text?.trim() || ""
  const mediaText = attachmentContextText(message)
  const body = role === "assistant" ? text : [`${display}: ${text || "(no text)"}`, mediaText].filter(Boolean).join("\n")
  const fileParts: AgentPromptPart[] =
    role === "assistant" ? [] : buildAttachmentPromptParts(message).map((file) => ({ type: "file", file }))
  return { role, parts: [textPart(body), ...fileParts], id: String(message.globalId), createdAt: message.date }
}
