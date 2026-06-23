export type AgentId = string
export type AgentRunId = string
export type AgentMessageId = string

export type JsonPrimitive = string | number | boolean | null
export type JsonArray = readonly JsonValue[]
export type JsonObject = { readonly [key: string]: JsonValue }
export type JsonValue = JsonPrimitive | JsonArray | JsonObject
export type JsonSchema = Readonly<Record<string, unknown>>

export type AgentScope =
  | {
      readonly type: "user"
      readonly userId: number
    }
  | {
      readonly type: "space"
      readonly spaceId: number
    }

export type AgentRole = "system" | "user" | "assistant" | "tool"

export type AgentFileKind = "image" | "video" | "audio" | "document" | "other"

export type AgentFileRef = {
  readonly id?: string
  readonly fileId?: number
  readonly kind: AgentFileKind
  readonly name?: string
  readonly mimeType?: string
  readonly sizeBytes?: number
  readonly signedUrl?: string
  readonly openaiFileId?: string
  readonly data?: Uint8Array
}

export type AgentMediaOutput = {
  readonly kind: AgentFileKind
  readonly name?: string
  readonly mimeType?: string
  readonly bytes?: Uint8Array
  readonly signedUrl?: string
  readonly providerFileId?: string
  readonly caption?: string
}

export type AgentTextPart = {
  readonly type: "text"
  readonly text: string
}

export type AgentFilePart = {
  readonly type: "file"
  readonly file: AgentFileRef
}

export type AgentToolCallPart = {
  readonly type: "tool_call"
  readonly id: string
  readonly name: string
  readonly args: unknown
  readonly provider?: ProviderMetadata
}

export type AgentToolResultPart = {
  readonly type: "tool_result"
  readonly id: string
  readonly name: string
  readonly result: AgentToolModelOutput
  readonly provider?: ProviderMetadata
}

export type AgentReasoningPart = {
  readonly type: "reasoning"
  readonly state: AgentProviderState
}

export type AgentPromptPart =
  | AgentTextPart
  | AgentFilePart
  | AgentToolCallPart
  | AgentToolResultPart
  | AgentReasoningPart

export type AgentPromptMessage = {
  readonly id?: AgentMessageId
  readonly role: AgentRole
  readonly parts: readonly AgentPromptPart[]
  readonly createdAt?: Date
  readonly provider?: ProviderMetadata
}

export type ProviderKey = string
export type ProviderMetadata = Readonly<Record<string, unknown>>

export type ProviderNativeTool = {
  readonly provider: ProviderKey
  readonly type: string
  readonly config?: ProviderMetadata
}

export type AgentProviderState = {
  readonly provider: ProviderKey
  readonly issuer?: string
  readonly model?: string
  readonly responseId?: string
  readonly encryptedItems?: readonly unknown[]
  readonly metadata?: ProviderMetadata
}

export type AgentToolModelOutput =
  | {
      readonly type: "text"
      readonly text: string
    }
  | {
      readonly type: "json"
      readonly value: unknown
    }
  | {
      readonly type: "media"
      readonly media: AgentMediaOutput
    }

export type AgentMaybePromise<T> = T | Promise<T>

export type AgentToolContext = {
  readonly runId: AgentRunId
  readonly agentId: AgentId
  readonly scope: AgentScope
  readonly actorUserId: number
  readonly signal?: AbortSignal
  readonly now: () => Date
}

export type AgentApprovalPolicy<Args = unknown> =
  | "never"
  | "always"
  | ((args: Args, ctx: AgentToolContext) => AgentMaybePromise<boolean>)

export type AgentToolHandler<Args = unknown, Result = unknown> = (
  args: Args,
  ctx: AgentToolContext,
) => AgentMaybePromise<Result>

export type AgentTool<Args = unknown, Result = unknown> = {
  readonly name: string
  readonly description?: string
  readonly parameters: JsonSchema
  readonly result?: JsonSchema
  readonly readOnly?: boolean
  readonly approval?: AgentApprovalPolicy<Args>
  readonly run: AgentToolHandler<Args, Result>
  readonly toModelOutput?: (result: Result, ctx: AgentToolContext) => AgentMaybePromise<AgentToolModelOutput>
}

export type AgentToolPack = {
  readonly name: string
  readonly tools: readonly AgentTool[]
}

export type AgentToolChoice =
  | "auto"
  | "none"
  | "required"
  | {
      readonly tool: string
    }

export type AgentRunStatus =
  | "pending"
  | "debouncing"
  | "running"
  | "streaming"
  | "waiting_for_tool"
  | "succeeded"
  | "failed"
  | "cancel_requested"
  | "canceled"
  | "interrupted"

export type AgentRunTerminalStatus = "succeeded" | "failed" | "canceled" | "interrupted"

export const AGENT_RUN_TERMINAL_STATUSES = ["succeeded", "failed", "canceled", "interrupted"] as const

const terminalStatuses = new Set<string>(AGENT_RUN_TERMINAL_STATUSES)

export function isAgentRunTerminalStatus(status: string): status is AgentRunTerminalStatus {
  return terminalStatuses.has(status)
}

export type AgentRunConfig = {
  readonly model?: string
  readonly toolChoice?: AgentToolChoice
  readonly maxOutputTokens?: number
  readonly temperature?: number
  readonly provider?: ProviderMetadata
}

export type AgentHarnessRequest = {
  readonly runId: AgentRunId
  readonly agentId: AgentId
  readonly scope: AgentScope
  readonly actorUserId: number
  readonly instructions: string
  readonly input: readonly AgentPromptMessage[]
  readonly tools?: readonly AgentTool[]
  readonly providerTools?: readonly ProviderNativeTool[]
  readonly config?: AgentRunConfig
  readonly signal?: AbortSignal
}

export type AgentTextStartStreamPart = {
  readonly type: "text_start"
  readonly index?: number
}

export type AgentTextDeltaStreamPart = {
  readonly type: "text_delta"
  readonly text: string
  readonly index?: number
}

export type AgentTextEndStreamPart = {
  readonly type: "text_end"
  readonly index?: number
}

export type AgentReasoningStreamPart = {
  readonly type: "reasoning"
  readonly state: AgentProviderState
}

export type AgentToolCallStreamPart = {
  readonly type: "tool_call"
  readonly id: string
  readonly name: string
  readonly args: unknown
  readonly provider?: ProviderMetadata
}

export type AgentToolResultStreamPart = {
  readonly type: "tool_result"
  readonly id: string
  readonly name: string
  readonly result: AgentToolModelOutput
  readonly provider?: ProviderMetadata
}

export type AgentMediaStreamPart = {
  readonly type: "media"
  readonly media: AgentMediaOutput
}

export type AgentSourceStreamPart = {
  readonly type: "source"
  readonly title?: string
  readonly url?: string
  readonly metadata?: ProviderMetadata
}

export type AgentFinishStreamPart = {
  readonly type: "finish"
  readonly status: AgentRunTerminalStatus
  readonly provider?: AgentProviderState
}

export type AgentErrorStreamPart = {
  readonly type: "error"
  readonly code: string
  readonly message: string
  readonly retryable?: boolean
}

export type AgentStreamPart =
  | AgentTextStartStreamPart
  | AgentTextDeltaStreamPart
  | AgentTextEndStreamPart
  | AgentReasoningStreamPart
  | AgentToolCallStreamPart
  | AgentToolResultStreamPart
  | AgentMediaStreamPart
  | AgentSourceStreamPart
  | AgentFinishStreamPart
  | AgentErrorStreamPart

export interface AgentHarness {
  readonly id: AgentId
  run(request: AgentHarnessRequest): AsyncIterable<AgentStreamPart>
}

export function textPart(text: string): AgentTextPart {
  return { type: "text", text }
}

export function textMessage(role: AgentRole, text: string): AgentPromptMessage {
  return { role, parts: [textPart(text)] }
}

export function mergeToolPacks(name: string, ...packs: readonly AgentToolPack[]): AgentToolPack {
  const tools: AgentTool[] = []
  const names = new Set<string>()

  for (const pack of packs) {
    for (const tool of pack.tools) {
      if (names.has(tool.name)) {
        throw new Error(`Duplicate agent tool: ${tool.name}`)
      }
      names.add(tool.name)
      tools.push(tool)
    }
  }

  return { name, tools }
}
