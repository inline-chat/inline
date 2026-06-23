import type { AgentPromptMessage } from "@inline-chat/agent-core"
import { CHATGPT_SYSTEM_PROMPT, CHATGPT_SYSTEM_PROMPT_VERSION } from "./system"
import { INLINE_MARKDOWN_GUIDE } from "./inlineGuide"
import { loadPromptHistory } from "./history"
import type { InputPeer } from "@inline-chat/protocol/core"

export type ChatgptPrompt = {
  readonly instructions: string
  readonly input: readonly AgentPromptMessage[]
  readonly promptVersion: string
  readonly priorOutputMsgGlobalIds: readonly bigint[]
}

export async function buildChatgptPrompt(input: {
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly triggerMessageId: number
}): Promise<ChatgptPrompt> {
  const history = await loadPromptHistory(input)
  const priorOutputMsgGlobalIds = history.messages
    .filter((message) => message.fromId === input.botUserId)
    .map((message) => message.globalId)

  return {
    instructions: [CHATGPT_SYSTEM_PROMPT, INLINE_MARKDOWN_GUIDE].join("\n\n"),
    input: history.prompt,
    promptVersion: CHATGPT_SYSTEM_PROMPT_VERSION,
    priorOutputMsgGlobalIds,
  }
}
