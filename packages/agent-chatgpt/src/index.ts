export const CHATGPT_AGENT_KEY = "chatgpt"
export const CHATGPT_CONNECTION_PROVIDER = "openai_codex"
export const CHATGPT_BOT_ALIASES = ["chat", "chatgpt", "gpt"] as const

export const OPENAI_AUTH_BASE_URL = "https://auth.openai.com"
export const OPENAI_CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
export const OPENAI_CODEX_RESPONSES_BASE_URL = "https://chatgpt.com/backend-api/codex"
export const OPENAI_CODEX_DEFAULT_MODEL = "gpt-5.5"

export type ChatgptBotAlias = (typeof CHATGPT_BOT_ALIASES)[number]

export type ChatgptMcpApproval = "always" | "never"

export type ChatgptProviderTool =
  | {
      readonly type: "web_search"
      readonly filters?: Record<string, unknown>
      readonly externalWebAccess?: boolean
      readonly returnTokenBudget?: number
    }
  | {
      readonly type: "image_generation"
      readonly action?: "auto" | "generate" | "edit"
      readonly model?: string
      readonly size?: string
      readonly quality?: "auto" | "low" | "medium" | "high"
      readonly outputFormat?: "png" | "jpeg" | "webp"
      readonly outputCompression?: number
      readonly background?: "auto" | "transparent" | "opaque"
      readonly partialImages?: number
    }
  | {
      readonly type: "file_search"
      readonly vectorStoreIds: readonly string[]
      readonly maxNumResults?: number
      readonly filters?: Record<string, unknown>
    }
  | {
      readonly type: "code_interpreter"
      readonly container: ChatgptCodeInterpreterContainer
    }
  | {
      readonly type: "mcp"
      readonly serverLabel: string
      readonly serverUrl?: string
      readonly connectorId?: string
      readonly serverDescription?: string
      readonly authorization?: string
      readonly requireApproval?: ChatgptMcpApproval
      readonly allowedTools?: readonly string[]
    }

export type ChatgptCodeInterpreterContainer =
  | "auto"
  | string
  | {
      readonly type: "auto"
      readonly memoryLimit?: "1g" | "4g" | "16g" | "64g"
      readonly fileIds?: readonly string[]
    }
  | {
      readonly id: string
    }

export type ChatgptEncodedTool = Record<string, unknown>

export type ChatgptServerTool = {
  readonly name: string
  readonly description?: string
  readonly parameters: Readonly<Record<string, unknown>>
}

export type ChatgptToolListInput = {
  readonly providerTools?: readonly ChatgptProviderTool[]
  readonly serverTools?: readonly ChatgptServerTool[]
  readonly strictServerTools?: boolean
}

export function encodeChatgptProviderTool(tool: ChatgptProviderTool): ChatgptEncodedTool {
  switch (tool.type) {
    case "web_search":
      return withoutUndefined({
        type: "web_search",
        filters: tool.filters,
        external_web_access: tool.externalWebAccess,
        return_token_budget: tool.returnTokenBudget,
      })

    case "image_generation":
      return withoutUndefined({
        type: "image_generation",
        action: tool.action,
        model: tool.model,
        size: tool.size,
        quality: tool.quality,
        output_format: tool.outputFormat,
        output_compression: tool.outputCompression,
        background: tool.background,
        partial_images: tool.partialImages,
      })

    case "file_search":
      return withoutUndefined({
        type: "file_search",
        vector_store_ids: [...tool.vectorStoreIds],
        max_num_results: tool.maxNumResults,
        filters: tool.filters,
      })

    case "code_interpreter":
      return {
        type: "code_interpreter",
        container: encodeCodeInterpreterContainer(tool.container),
      }

    case "mcp":
      return withoutUndefined({
        type: "mcp",
        server_label: tool.serverLabel,
        server_url: tool.serverUrl,
        connector_id: tool.connectorId,
        server_description: tool.serverDescription,
        authorization: tool.authorization,
        require_approval: tool.requireApproval,
        allowed_tools: tool.allowedTools ? [...tool.allowedTools] : undefined,
      })
  }
}

export function encodeChatgptServerTool(tool: ChatgptServerTool, options: { readonly strict?: boolean } = {}): ChatgptEncodedTool {
  return withoutUndefined({
    type: "function",
    name: tool.name,
    description: tool.description,
    parameters: tool.parameters,
    strict: options.strict,
  })
}

export function buildChatgptToolList(input: ChatgptToolListInput): readonly ChatgptEncodedTool[] | undefined {
  const tools = [
    ...(input.providerTools ?? []).map(encodeChatgptProviderTool),
    ...(input.serverTools ?? []).map((tool) => encodeChatgptServerTool(tool, { strict: input.strictServerTools })),
  ]

  return tools.length === 0 ? undefined : tools
}

export function isChatgptEncryptedReasoningError(value: unknown): boolean {
  const text = errorText(value).toLowerCase()

  return text.includes("invalid_encrypted_content") || text.includes("invalid encrypted content")
}

function encodeCodeInterpreterContainer(container: ChatgptCodeInterpreterContainer): unknown {
  if (container === "auto") {
    return { type: "auto" }
  }

  if (typeof container === "string") {
    return container
  }

  if ("id" in container) {
    return container.id
  }

  return withoutUndefined({
    type: "auto",
    memory_limit: container.memoryLimit,
    file_ids: container.fileIds ? [...container.fileIds] : undefined,
  })
}

function withoutUndefined(values: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(values).filter((entry) => entry[1] !== undefined))
}

function errorText(value: unknown): string {
  if (value instanceof Error) {
    return `${value.name} ${value.message}`
  }

  if (typeof value === "object" && value !== null) {
    const record = value as Record<string, unknown>
    const parts = [record["code"], record["type"], record["message"], record["error"]].filter(
      (part): part is string => typeof part === "string",
    )

    return parts.join(" ")
  }

  return String(value)
}
