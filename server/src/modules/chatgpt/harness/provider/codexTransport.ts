import OpenAI from "openai"
import {
  buildChatgptToolList,
  isChatgptEncryptedReasoningError,
  OPENAI_CODEX_DEFAULT_MODEL,
  OPENAI_CODEX_RESPONSES_BASE_URL,
  type ChatgptProviderTool,
} from "@inline-chat/agent-chatgpt"
import type { AgentMediaOutput, AgentPromptMessage, AgentPromptPart, AgentStreamPart } from "@inline-chat/agent-core"
import { Log } from "@in/server/utils/log"

const log = new Log("chatgpt.codex")
const loggedUnsupportedShapes = new Set<string>()

export type CodexRunInput = {
  readonly runId?: string
  readonly connectionId?: number
  readonly accessToken: string
  readonly model?: string
  readonly instructions: string
  readonly input: readonly AgentPromptMessage[]
  readonly replayItems?: readonly unknown[]
  readonly providerTools?: readonly ChatgptProviderTool[]
  readonly promptCacheKey?: string
  readonly signal?: AbortSignal
}

export type CodexRunResult = {
  readonly stream: AsyncIterable<AgentStreamPart>
  readonly model: string
}

export function runCodexResponses(input: CodexRunInput): CodexRunResult {
  const model = input.model ?? OPENAI_CODEX_DEFAULT_MODEL
  return {
    model,
    stream: streamCodexResponses(input, model),
  }
}

async function* streamCodexResponses(input: CodexRunInput, model: string): AsyncIterable<AgentStreamPart> {
  const meta = buildCodexRunMetadata(input, model)
  try {
    yield* streamCodexResponsesOnce(input, model, {
      replayItems: input.replayItems,
      providerTools: input.providerTools,
    })
  } catch (error) {
    const errorMeta = codexErrorMetadata(error)
    if (isChatgptEncryptedReasoningError(error) && (input.replayItems?.length ?? 0) > 0) {
      log.warn("Retrying ChatGPT Codex request without encrypted reasoning replay", {
        ...meta,
        error: errorMeta,
      })
      yield* streamCodexResponsesOnce(input, model, {
        replayItems: [],
        providerTools: input.providerTools,
      })
      return
    }

    if (isLikelyToolShapeError(error) && (input.providerTools?.length ?? 0) > 0) {
      log.warn("Retrying ChatGPT Codex request without provider-native tools", {
        ...meta,
        reason: isOpaqueBadRequest(error) ? "opaque_bad_request" : "tool_shape_error",
        error: errorMeta,
      })
      yield* streamCodexResponsesOnce(input, model, {
        replayItems: input.replayItems,
        providerTools: [],
      })
      return
    }

    log.warn("ChatGPT Codex request failed without fallback", {
      ...meta,
      error: errorMeta,
    })
    throw error
  }
}

async function* streamCodexResponsesOnce(
  input: CodexRunInput,
  model: string,
  options: {
    readonly replayItems?: readonly unknown[]
    readonly providerTools?: readonly ChatgptProviderTool[]
  },
): AsyncIterable<AgentStreamPart> {
  const client = new OpenAI({
    apiKey: input.accessToken,
    baseURL: OPENAI_CODEX_RESPONSES_BASE_URL,
  })

  const tools = buildChatgptToolList({ providerTools: options.providerTools })
  const responsesInput = buildResponsesInput(input.input, options.replayItems)
  const attemptMeta = buildCodexRunMetadata(input, model, {
    replayItems: options.replayItems,
    providerTools: options.providerTools,
    encodedTools: tools,
    responsesInput,
  })
  const params = withoutUndefined({
    model,
    instructions: input.instructions,
    input: responsesInput,
    tools,
    tool_choice: tools ? "auto" : undefined,
    parallel_tool_calls: tools ? true : undefined,
    stream: true,
    store: false,
    prompt_cache_key: input.promptCacheKey,
    reasoning: {
      effort: "medium",
      summary: "auto",
    },
    include: ["reasoning.encrypted_content", "code_interpreter_call.outputs"],
  })

  log.debug("Starting ChatGPT Codex request", attemptMeta)

  const stream = await createResponseStream(client, params, input.signal, attemptMeta)

  let responseId: string | undefined
  const replayItems: unknown[] = []
  const pendingImageGenerationMedia = new Map<string, AgentMediaOutput>()
  const emittedImageGenerationIds = new Set<string>()

  for await (const event of stream) {
    const type = readString(event["type"])
    if (type === "response.created") {
      responseId = readNestedString(event, "response", "id") ?? responseId
      log.debug("ChatGPT Codex response created", withoutUndefined({ runId: input.runId, model, responseId }))
      continue
    }

    if (type === "response.output_text.delta" || type === "response.refusal.delta") {
      const text = readString(event["delta"])
      if (text) {
        yield { type: "text_delta", text }
      }
      continue
    }

    if (type === "response.image_generation_call.partial_image") {
      const partial = extractMediaFromImageGenerationPartialEvent(event)
      if (partial) {
        pendingImageGenerationMedia.set(partial.itemId, partial.media)
      }
      continue
    }

    if (type === "response.output_item.done") {
      const item = event["item"]
      const itemType = item && typeof item === "object" ? readString((item as Record<string, unknown>)["type"]) : undefined
      const media = extractMediaFromOutputItem(item)
      const itemId = item && typeof item === "object" ? readString((item as Record<string, unknown>)["id"]) : undefined
      if (itemType === "image_generation_call" && media.length > 0 && itemId) {
        emittedImageGenerationIds.add(itemId)
      }
      if (itemType === "reasoning" || itemType === "message") {
        replayItems.push(sanitizeReplayItem(item))
      }
      for (const output of media) {
        yield { type: "media", media: output }
      }
      if (media.length > 0) {
        log.debug("ChatGPT Codex emitted media output", {
          runId: input.runId,
          model,
          itemType,
          mediaCount: media.length,
          mediaKinds: media.map((output) => output.kind),
        })
      }
      logUnsupportedOutputItem(itemType, item, media.length, { runId: input.runId, model })
      continue
    }

    if (type === "response.completed") {
      responseId = readNestedString(event, "response", "id") ?? responseId
      for (const [itemId, media] of pendingImageGenerationMedia) {
        if (emittedImageGenerationIds.has(itemId)) {
          continue
        }
        emittedImageGenerationIds.add(itemId)
        yield { type: "media", media }
      }
      log.debug("ChatGPT Codex response completed", {
        runId: input.runId,
        model,
        responseId,
        replayItemCount: replayItems.length,
      })
      yield {
        type: "finish",
        status: "succeeded",
        provider: {
          provider: "openai_codex",
          issuer: "chatgpt_codex",
          model,
          responseId,
          encryptedItems: replayItems,
        },
      }
      return
    }

    if (type === "response.failed" || type === "error") {
      const message = readNestedString(event, "error", "message") ?? readString(event["message"]) ?? "Codex request failed"
      log.warn("ChatGPT Codex stream failed event", {
        runId: input.runId,
        model,
        eventType: type,
        message,
        eventKeys: Object.keys(event).slice(0, 24),
      })
      throw new Error(message)
    }

    if (type) {
      logUnsupportedEvent(type, event, { runId: input.runId, model })
      continue
    }
  }
}

async function createResponseStream(
  client: OpenAI,
  params: Record<string, unknown>,
  signal: AbortSignal | undefined,
  attemptMeta: Record<string, unknown>,
): Promise<AsyncIterable<Record<string, unknown>>> {
  try {
    return (await client.responses.create(params as never, { signal })) as unknown as AsyncIterable<Record<string, unknown>>
  } catch (error) {
    log.warn("ChatGPT Codex request rejected before stream", {
      ...attemptMeta,
      error: codexErrorMetadata(error),
    })
    throw error
  }
}

const unsupportedRichEventReasons: Record<string, string> = {
  "response.code_interpreter_call.code.delta": "Inline does not yet render live code-interpreter execution panes for bot replies.",
  "response.code_interpreter_call.code.done": "Inline does not yet render code-interpreter execution panes for bot replies.",
  "response.output_text.annotation.added": "Inline markdown replies do not yet preserve provider citation/source annotations.",
  "response.mcp_call.in_progress": "Inline does not yet expose provider-native MCP progress UI for bot replies.",
  "response.mcp_call.completed": "Inline does not yet expose provider-native MCP result UI for bot replies.",
  "response.mcp_call.failed": "Inline does not yet expose provider-native MCP failure UI for bot replies.",
  "response.mcp_list_tools.in_progress": "Inline does not yet expose provider-native MCP tool discovery UI for bot replies.",
  "response.mcp_list_tools.completed": "Inline does not yet expose provider-native MCP tool discovery UI for bot replies.",
  "response.mcp_list_tools.failed": "Inline does not yet expose provider-native MCP tool discovery UI for bot replies.",
}

export function extractMediaFromOutputItem(item: unknown): AgentMediaOutput[] {
  if (!item || typeof item !== "object") {
    return []
  }

  const record = item as Record<string, unknown>
  const type = readString(record["type"])
  if (type === "image_generation_call") {
    const bytes = decodeBase64(readString(record["result"]))
    if (!bytes) {
      return []
    }

    return [
      {
        kind: "image",
        name: "generated-image.png",
        mimeType: "image/png",
        bytes,
        providerFileId: readString(record["id"]),
        caption: "Generated image",
      },
    ]
  }

  if (type !== "code_interpreter_call") {
    return []
  }

  const outputs = Array.isArray(record["outputs"]) ? record["outputs"] : []
  return outputs.flatMap((output, index) => {
    if (!output || typeof output !== "object") {
      return []
    }

    const outputRecord = output as Record<string, unknown>
    if (readString(outputRecord["type"]) !== "image") {
      return []
    }

    const url = readString(outputRecord["url"])
    if (!url) {
      return []
    }

    return [
      {
        kind: "image",
        name: `code-output-${index + 1}.png`,
        mimeType: "image/png",
        signedUrl: url,
        providerFileId: readString(record["id"]),
        caption: "Code interpreter image output",
      },
    ]
  })
}

export function extractMediaFromImageGenerationPartialEvent(
  event: Record<string, unknown>,
): { readonly itemId: string; readonly media: AgentMediaOutput } | undefined {
  const itemId = readString(event["item_id"])
  const index = readNumber(event["partial_image_index"]) ?? 0
  const bytes = decodeBase64(readString(event["partial_image_b64"]))
  if (!itemId || !bytes) {
    return undefined
  }

  return {
    itemId,
    media: {
      kind: "image",
      name: `generated-image-${index + 1}.png`,
      mimeType: "image/png",
      bytes,
      providerFileId: itemId,
      caption: "Generated image",
    },
  }
}

function logUnsupportedEvent(
  type: string,
  event: Record<string, unknown>,
  context: { readonly runId?: string; readonly model: string },
): void {
  const reason = unsupportedRichEventReasons[type]
  if (!reason) {
    return
  }

  logUnsupportedShape(`event:${type}`, "Unsupported ChatGPT response event", {
    reason,
    type,
    runId: context.runId,
    model: context.model,
    keys: Object.keys(event).slice(0, 24),
  })
}

function logUnsupportedOutputItem(
  itemType: string | undefined,
  item: unknown,
  emittedMediaCount: number,
  context: { readonly runId?: string; readonly model: string },
): void {
  if (!itemType || !item || typeof item !== "object") {
    return
  }

  const record = item as Record<string, unknown>
  if (itemType === "image_generation_call" && emittedMediaCount === 0) {
    logUnsupportedShape("item:image_generation_call:no_result", "Unsupported ChatGPT response item", {
      reason: "Image generation completed without base64 bytes that Inline can upload.",
      type: itemType,
      runId: context.runId,
      model: context.model,
      status: readString(record["status"]),
      keys: Object.keys(record).slice(0, 24),
    })
    return
  }

  if (itemType === "code_interpreter_call") {
    const outputs = Array.isArray(record["outputs"]) ? record["outputs"] : []
    const outputTypes = outputs
      .map((output) => (output && typeof output === "object" ? readString((output as Record<string, unknown>)["type"]) : undefined))
      .filter((type): type is string => !!type)

    if (outputTypes.length > 0) {
      logUnsupportedShape(`item:code_interpreter_call:${outputTypes.join(",")}`, "Unsupported ChatGPT response item", {
        reason: "Code interpreter outputs need download/persist adapters or richer Inline execution UI.",
        type: itemType,
        runId: context.runId,
        model: context.model,
        outputTypes,
        hasContainerId: !!readString(record["container_id"]),
      })
    }
    return
  }

  if (itemType.includes("mcp") || itemType === "mcp_approval_request") {
    logUnsupportedShape(`item:${itemType}`, "Unsupported ChatGPT response item", {
      reason: "Provider-native MCP interactions need Inline approval/progress/result UI before rendering.",
      type: itemType,
      runId: context.runId,
      model: context.model,
      keys: Object.keys(record).slice(0, 24),
    })
  }
}

function logUnsupportedShape(key: string, message: string, metadata: Record<string, unknown>): void {
  if (loggedUnsupportedShapes.has(key)) {
    return
  }

  loggedUnsupportedShapes.add(key)
  log.warn(message, metadata)
}

function buildResponsesInput(messages: readonly AgentPromptMessage[], replayItems: readonly unknown[] | undefined): unknown[] {
  const input: unknown[] = []
  for (const item of replayItems ?? []) {
    if (item && typeof item === "object") {
      input.push(sanitizeReplayItem(item))
    }
  }
  for (const message of messages) {
    input.push({
      role: message.role === "assistant" ? "assistant" : "user",
      content: message.parts.flatMap((part) => convertPart(part, message.role)),
    })
  }
  if (input.length === 0) {
    input.push({ role: "user", content: [{ type: "input_text", text: " " }] })
  }
  return input
}

export function buildCodexResponsesInputForTest(
  messages: readonly AgentPromptMessage[],
  replayItems?: readonly unknown[],
): unknown[] {
  return buildResponsesInput(messages, replayItems)
}

function convertPart(part: AgentPromptPart, role: AgentPromptMessage["role"]): unknown[] {
  const textType = role === "assistant" ? "output_text" : "input_text"
  switch (part.type) {
    case "text":
      return part.text ? [{ type: textType, text: part.text }] : []
    case "file":
      if (part.file.kind === "image" && part.file.signedUrl) {
        return [{ type: "input_image", image_url: part.file.signedUrl, detail: "auto" }]
      }
      if (part.file.signedUrl) {
        return [
          {
            type: "input_file",
            file_url: part.file.signedUrl,
            filename: part.file.name ?? "file",
          },
        ]
      }
      return [{ type: "input_text", text: `[${part.file.kind} attachment unavailable: ${part.file.name ?? "file"}]` }]
    case "reasoning":
      return part.state.encryptedItems ? [...part.state.encryptedItems] : []
    case "tool_call":
    case "tool_result":
      return []
  }
}

function sanitizeReplayItem(value: unknown): unknown {
  if (!value || typeof value !== "object") {
    return value
  }

  const item = value as Record<string, unknown>
  const type = readString(item["type"])
  if (type === "reasoning") {
    return withoutUndefined({
      type,
      encrypted_content: item["encrypted_content"],
      summary: Array.isArray(item["summary"]) ? item["summary"] : [],
    })
  }

  if (type === "message") {
    return withoutUndefined({
      type,
      id: readString(item["id"]),
      role: item["role"],
      status: item["status"],
      phase: item["phase"],
      content: item["content"],
    })
  }

  return value
}

function buildCodexRunMetadata(
  input: CodexRunInput,
  model: string,
  attempt?: {
    readonly replayItems?: readonly unknown[]
    readonly providerTools?: readonly ChatgptProviderTool[]
    readonly encodedTools?: readonly Record<string, unknown>[]
    readonly responsesInput?: readonly unknown[]
  },
): Record<string, unknown> {
  const providerTools = attempt?.providerTools ?? input.providerTools ?? []
  const replayItems = attempt?.replayItems ?? input.replayItems ?? []
  return withoutUndefined({
    runId: input.runId,
    connectionId: input.connectionId,
    model,
    prompt: summarizePrompt(input.input),
    replay: summarizeReplayItems(replayItems),
    providerToolCount: providerTools.length,
    providerToolTypes: providerTools.map((tool) => tool.type),
    encodedToolTypes: attempt?.encodedTools?.map((tool) => readString(tool["type"]) ?? "unknown"),
    responsesInput: attempt?.responsesInput ? summarizeResponsesInput(attempt.responsesInput) : undefined,
    hasPromptCacheKey: !!input.promptCacheKey,
    signalAborted: input.signal?.aborted,
  })
}

function summarizePrompt(messages: readonly AgentPromptMessage[]): Record<string, unknown> {
  const roles: Record<string, number> = {}
  const partTypes: Record<string, number> = {}
  const fileKinds: Record<string, number> = {}
  let textCharCount = 0
  let signedUrlFileCount = 0
  let unavailableFileCount = 0
  let mediaPartCount = 0
  let reasoningItemCount = 0

  for (const message of messages) {
    roles[message.role] = (roles[message.role] ?? 0) + 1
    for (const part of message.parts) {
      partTypes[part.type] = (partTypes[part.type] ?? 0) + 1
      switch (part.type) {
        case "text":
          textCharCount += part.text.length
          break
        case "file":
          fileKinds[part.file.kind] = (fileKinds[part.file.kind] ?? 0) + 1
          signedUrlFileCount += part.file.signedUrl ? 1 : 0
          unavailableFileCount += part.file.signedUrl ? 0 : 1
          mediaPartCount += part.file.kind === "image" || part.file.kind === "video" || part.file.kind === "audio" ? 1 : 0
          break
        case "reasoning":
          reasoningItemCount += part.state.encryptedItems?.length ?? 0
          break
        case "tool_call":
        case "tool_result":
          break
      }
    }
  }

  return {
    messageCount: messages.length,
    roles,
    partTypes,
    fileKinds,
    textCharCount,
    signedUrlFileCount,
    unavailableFileCount,
    mediaPartCount,
    reasoningItemCount,
  }
}

function summarizeReplayItems(items: readonly unknown[]): Record<string, unknown> {
  const types: Record<string, number> = {}
  let reasoningWithEncryptedContent = 0
  let reasoningWithProviderId = 0
  let unknownObjectCount = 0

  for (const item of items) {
    if (!item || typeof item !== "object") {
      types[typeof item] = (types[typeof item] ?? 0) + 1
      continue
    }

    const record = item as Record<string, unknown>
    const type = readString(record["type"]) ?? "unknown"
    types[type] = (types[type] ?? 0) + 1
    unknownObjectCount += type === "unknown" ? 1 : 0
    if (type === "reasoning") {
      reasoningWithEncryptedContent += typeof record["encrypted_content"] === "string" ? 1 : 0
      reasoningWithProviderId += typeof record["id"] === "string" ? 1 : 0
    }
  }

  return {
    itemCount: items.length,
    types,
    reasoningWithEncryptedContent,
    reasoningWithProviderId,
    unknownObjectCount,
  }
}

function summarizeResponsesInput(items: readonly unknown[]): Record<string, unknown> {
  const itemTypes: Record<string, number> = {}
  const roles: Record<string, number> = {}
  const contentTypes: Record<string, number> = {}

  for (const item of items) {
    if (!item || typeof item !== "object") {
      itemTypes[typeof item] = (itemTypes[typeof item] ?? 0) + 1
      continue
    }

    const record = item as Record<string, unknown>
    const itemType = readString(record["type"]) ?? "message"
    itemTypes[itemType] = (itemTypes[itemType] ?? 0) + 1
    const role = readString(record["role"])
    if (role) {
      roles[role] = (roles[role] ?? 0) + 1
    }

    const content = Array.isArray(record["content"]) ? record["content"] : []
    for (const part of content) {
      if (!part || typeof part !== "object") {
        contentTypes[typeof part] = (contentTypes[typeof part] ?? 0) + 1
        continue
      }
      const contentType = readString((part as Record<string, unknown>)["type"]) ?? "unknown"
      contentTypes[contentType] = (contentTypes[contentType] ?? 0) + 1
    }
  }

  return {
    itemCount: items.length,
    itemTypes,
    roles,
    contentTypes,
  }
}

export function codexErrorMetadataForTest(error: unknown): Record<string, unknown> {
  return codexErrorMetadata(error)
}

function codexErrorMetadata(error: unknown): Record<string, unknown> {
  if (!error || typeof error !== "object") {
    return { message: String(error) }
  }

  const record = error as Record<string, unknown>
  const headers = record["headers"] && typeof record["headers"] === "object" ? (record["headers"] as Record<string, unknown>) : undefined
  const body = record["body"]
  const providerError = record["error"]
  return withoutUndefined({
    name: error instanceof Error ? error.name : readString(record["name"]),
    message: error instanceof Error ? error.message : readString(record["message"]),
    status: typeof record["status"] === "number" ? record["status"] : undefined,
    code: readString(record["code"]) ?? readNestedErrorString(providerError, "code"),
    type: readString(record["type"]) ?? readNestedErrorString(providerError, "type"),
    param: readString(record["param"]) ?? readNestedErrorString(providerError, "param"),
    requestId: readString(record["request_id"]) ?? readString(record["requestID"]) ?? readHeader(headers, "x-request-id"),
    hasBody: body !== undefined || providerError !== undefined,
    bodyType: body === undefined ? undefined : Array.isArray(body) ? "array" : typeof body,
    bodyKeys: body && typeof body === "object" && !Array.isArray(body) ? Object.keys(body).slice(0, 24) : undefined,
    errorKeys:
      providerError && typeof providerError === "object" && !Array.isArray(providerError)
        ? Object.keys(providerError).slice(0, 24)
        : undefined,
    cause: summarizeErrorCause(record["cause"]),
  })
}

function summarizeErrorCause(cause: unknown): Record<string, unknown> | undefined {
  if (!cause || typeof cause !== "object") {
    return undefined
  }

  const record = cause as Record<string, unknown>
  return withoutUndefined({
    name: cause instanceof Error ? cause.name : readString(record["name"]),
    message: cause instanceof Error ? cause.message : readString(record["message"]),
    code: readString(record["code"]),
    type: readString(record["type"]),
  })
}

function isLikelyToolShapeError(error: unknown): boolean {
  const text = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase()
  if (text.includes("tool") && (text.includes("invalid") || text.includes("unsupported") || text.includes("unknown"))) {
    return true
  }

  return isOpaqueBadRequest(error)
}

function isOpaqueBadRequest(error: unknown): boolean {
  if (!error || typeof error !== "object") {
    return false
  }

  const record = error as Record<string, unknown>
  const status = typeof record["status"] === "number" ? record["status"] : undefined
  const message = error instanceof Error ? error.message.toLowerCase() : String(record["message"] ?? "").toLowerCase()
  const hasBody =
    record["error"] !== undefined ||
    record["body"] !== undefined ||
    record["code"] !== undefined ||
    record["param"] !== undefined ||
    record["type"] !== undefined

  return status === 400 && !hasBody && (message.includes("400") || message.includes("bad request"))
}

function readString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined
}

function readNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined
}

function readNestedString(value: Record<string, unknown>, key: string, nested: string): string | undefined {
  const record = value[key]
  if (!record || typeof record !== "object") {
    return undefined
  }
  return readString((record as Record<string, unknown>)[nested])
}

function readNestedErrorString(value: unknown, key: string): string | undefined {
  if (!value || typeof value !== "object") {
    return undefined
  }
  return readString((value as Record<string, unknown>)[key])
}

function readHeader(headers: Record<string, unknown> | undefined, key: string): string | undefined {
  if (!headers) {
    return undefined
  }

  return readString(headers[key]) ?? readString(headers[key.toLowerCase()]) ?? readString(headers[key.toUpperCase()])
}

function decodeBase64(value: string | undefined): Uint8Array | undefined {
  if (!value) {
    return undefined
  }

  try {
    const bytes = Buffer.from(value, "base64")
    return bytes.byteLength > 0 ? bytes : undefined
  } catch {
    return undefined
  }
}

function withoutUndefined(values: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(values).filter((entry) => entry[1] !== undefined))
}
