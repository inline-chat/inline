import type {
  BotApiEnvelope,
  BotMethodName,
  BotMethodParamsByName,
  BotMethodResultByName,
  CreateReplyThreadParams,
  CreateThreadParams,
  AnswerMessageActionParams,
  DeleteReactionParams,
  DeleteWebhookParams,
  DeleteMessageParams,
  ForwardMessageParams,
  EditMessageTextParams,
  GetChatHistoryParams,
  GetChatParams,
  GetChatParticipantParams,
  GetChatParticipantCountParams,
  GetFileParams,
  GetMessagesParams,
  GetUpdatesParams,
  InlineBotApiClientOptions,
  InlineBotApiMethodOptions,
  InlineBotApiRequestOptions,
  InlineBotApiResponse,
  SetMyCommandsParams,
  SendMessageParams,
  SendReactionParams,
  SendChatActionParams,
  PinMessageParams,
  UnpinMessageParams,
  SetThreadTitleParams,
  SearchMessagesParams,
  SetWebhookParams,
  UploadFileParams,
  UploadFileResult,
} from "./types.js"

const defaultBaseUrl = "https://api.inline.chat"

const getMethodNames = new Set<BotMethodName>([
  "getMe",
  "getChat",
  "getChatHistory",
  "getChatParticipant",
  "getChatParticipantCount",
  "getMyCommands",
  "getFile",
  "getUpdates",
  "getWebhookInfo",
])

function isGetMethod(
  method: string,
): method is "getMe" | "getChat" | "getChatHistory" | "getChatParticipant" | "getChatParticipantCount" | "getMyCommands" | "getFile" | "getUpdates" | "getWebhookInfo" {
  return getMethodNames.has(method as BotMethodName)
}

function normalizeBaseUrl(baseUrl: string): string {
  return baseUrl.replace(/\/+$/, "")
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function serializeQueryValue(value: unknown): string {
  if (value === null) return "null"
  if (typeof value === "string") return value
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") {
    return String(value)
  }
  return JSON.stringify(value)
}

function setQueryParams(url: URL, query: Record<string, unknown>) {
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined) continue
    url.searchParams.set(key, serializeQueryValue(value))
  }
}

export class InlineBotApiClient {
  private readonly baseUrl: string
  private readonly token: string
  private readonly authMode: "header" | "path"
  private readonly fetchImpl: typeof fetch

  constructor(options: InlineBotApiClientOptions) {
    this.baseUrl = normalizeBaseUrl(options.baseUrl ?? defaultBaseUrl)
    this.token = options.token
    this.authMode = options.authMode ?? "header"
    this.fetchImpl = options.fetch ?? fetch
  }

  private methodPath(method: string): string {
    if (this.authMode === "path") {
      return `/bot${this.token}/${method}`
    }
    return `/bot/${method}`
  }

  private applyAuth(headers: Headers) {
    if (this.authMode === "header") {
      headers.set("authorization", `Bearer ${this.token}`)
    }
  }

  // Low-level escape hatch with auth attached.
  async requestRaw<T = unknown>(path: string, options?: InlineBotApiRequestOptions): Promise<InlineBotApiResponse<T>> {
    const normalizedPath = path.startsWith("/") ? path : `/${path}`
    const url = new URL(normalizedPath, this.baseUrl + "/")
    const method = options?.method ?? "POST"
    const headers = new Headers(options?.headers)
    this.applyAuth(headers)

    if (options?.query && isRecord(options.query)) {
      setQueryParams(url, options.query)
    }

    let body: BodyInit | undefined
    if (options?.body !== undefined) {
      headers.set("content-type", "application/json")
      body = JSON.stringify(options.body)
    }

    const res = await this.fetchImpl(url, {
      method,
      headers,
      body,
      signal: options?.signal,
    })

    const contentType = res.headers.get("content-type") ?? ""
    const data =
      contentType.includes("application/json") ? ((await res.json()) as T) : ((await res.text()) as unknown as T)

    return { status: res.status, headers: res.headers, data }
  }

  async methodRaw<M extends BotMethodName>(
    method: M,
    params: BotMethodParamsByName[M],
    options?: InlineBotApiMethodOptions,
  ): Promise<InlineBotApiResponse<BotApiEnvelope<BotMethodResultByName[M]>>>
  async methodRaw<T>(
    method: string,
    params?: Record<string, unknown>,
    options?: InlineBotApiMethodOptions,
  ): Promise<InlineBotApiResponse<BotApiEnvelope<T>>> {
    const methodPath = this.methodPath(method)
    const isGet = isGetMethod(method)
    const httpMethod = isGet ? "GET" : "POST"
    const postAs = options?.postAs ?? "json"

    const requestOptions: InlineBotApiRequestOptions = {
      method: httpMethod,
      headers: options?.headers,
      signal: options?.signal,
    }

    if (isGet) {
      requestOptions.query = params
    } else if (postAs === "query") {
      requestOptions.query = params
    } else {
      requestOptions.body = params
    }

    return this.requestRaw<BotApiEnvelope<T>>(methodPath, requestOptions)
  }

  async method<M extends BotMethodName>(
    method: M,
    params: BotMethodParamsByName[M],
    options?: InlineBotApiMethodOptions,
  ): Promise<BotApiEnvelope<BotMethodResultByName[M]>>
  async method<T>(
    method: string,
    params?: Record<string, unknown>,
    options?: InlineBotApiMethodOptions,
  ): Promise<BotApiEnvelope<T>> {
    const res = await (this.methodRaw as (
      method: string,
      params?: Record<string, unknown>,
      options?: InlineBotApiMethodOptions,
    ) => Promise<InlineBotApiResponse<BotApiEnvelope<T>>>)(method, params, options)
    return res.data as BotApiEnvelope<T>
  }

  getMe(options?: InlineBotApiMethodOptions) {
    return this.method("getMe", undefined, options)
  }

  getChat(params: GetChatParams, options?: InlineBotApiMethodOptions) {
    return this.method("getChat", params, options)
  }

  getChatHistory(params: GetChatHistoryParams, options?: InlineBotApiMethodOptions) {
    return this.method("getChatHistory", params, options)
  }

  getMessages(params: GetMessagesParams, options?: InlineBotApiMethodOptions) {
    return this.method("getMessages", params, options)
  }

  searchMessages(params: SearchMessagesParams, options?: InlineBotApiMethodOptions) {
    return this.method("searchMessages", params, options)
  }

  createThread(params: CreateThreadParams, options?: InlineBotApiMethodOptions) {
    return this.method("createThread", params, options)
  }

  createReplyThread(params: CreateReplyThreadParams, options?: InlineBotApiMethodOptions) {
    return this.method("createReplyThread", params, options)
  }

  getMyCommands(options?: InlineBotApiMethodOptions) {
    return this.method("getMyCommands", undefined, options)
  }

  setMyCommands(params: SetMyCommandsParams, options?: InlineBotApiMethodOptions) {
    return this.method("setMyCommands", params, options)
  }

  deleteMyCommands(options?: InlineBotApiMethodOptions) {
    return this.method("deleteMyCommands", undefined, options)
  }

  sendMessage(params: SendMessageParams, options?: InlineBotApiMethodOptions) {
    return this.method("sendMessage", params, options)
  }

  editMessageText(params: EditMessageTextParams, options?: InlineBotApiMethodOptions) {
    return this.method("editMessageText", params, options)
  }

  deleteMessage(params: DeleteMessageParams, options?: InlineBotApiMethodOptions) {
    return this.method("deleteMessage", params, options)
  }

  forwardMessage(params: ForwardMessageParams, options?: InlineBotApiMethodOptions) {
    return this.method("forwardMessage", params, options)
  }

  pinMessage(params: PinMessageParams, options?: InlineBotApiMethodOptions) {
    return this.method("pinMessage", params, options)
  }

  unpinMessage(params: UnpinMessageParams, options?: InlineBotApiMethodOptions) {
    return this.method("unpinMessage", params, options)
  }

  getChatParticipant(params: GetChatParticipantParams, options?: InlineBotApiMethodOptions) {
    return this.method("getChatParticipant", params, options)
  }

  getChatParticipantCount(params: GetChatParticipantCountParams, options?: InlineBotApiMethodOptions) {
    return this.method("getChatParticipantCount", params, options)
  }

  setThreadTitle(params: SetThreadTitleParams, options?: InlineBotApiMethodOptions) {
    return this.method("setThreadTitle", params, options)
  }

  sendReaction(params: SendReactionParams, options?: InlineBotApiMethodOptions) {
    return this.method("sendReaction", params, options)
  }

  deleteReaction(params: DeleteReactionParams, options?: InlineBotApiMethodOptions) {
    return this.method("deleteReaction", params, options)
  }

  answerMessageAction(params: AnswerMessageActionParams, options?: InlineBotApiMethodOptions) {
    return this.method("answerMessageAction", params, options)
  }

  sendChatAction(params: SendChatActionParams, options?: InlineBotApiMethodOptions) {
    return this.method("sendChatAction", params, options)
  }

  getFile(params: GetFileParams, options?: InlineBotApiMethodOptions) {
    return this.method("getFile", params, options)
  }

  async uploadFile(params: UploadFileParams, options?: InlineBotApiMethodOptions): Promise<BotApiEnvelope<UploadFileResult>> {
    const form = new FormData()
    form.set("type", params.type)
    form.set("file", params.file, params.file_name ?? `upload.${params.type === "photo" ? "jpg" : "bin"}`)
    if (params.thumbnail) form.set("thumbnail", params.thumbnail, params.thumbnail_file_name ?? "thumbnail.jpg")
    if (params.width !== undefined) form.set("width", String(params.width))
    if (params.height !== undefined) form.set("height", String(params.height))
    if (params.duration !== undefined) form.set("duration", String(params.duration))
    if (params.is_animated !== undefined) form.set("is_animated", String(params.is_animated))
    if (params.has_audio !== undefined) form.set("has_audio", String(params.has_audio))
    if (params.waveform_base64 !== undefined) form.set("waveform_base64", params.waveform_base64)
    const headers = new Headers(options?.headers)
    this.applyAuth(headers)
    const response = await this.fetchImpl(new URL(this.methodPath("uploadFile"), this.baseUrl + "/"), {
      method: "POST",
      headers,
      body: form,
      signal: options?.signal,
    })
    return await response.json() as BotApiEnvelope<UploadFileResult>
  }

  getUpdates(params: GetUpdatesParams = {}, options?: InlineBotApiMethodOptions) {
    return this.method("getUpdates", params, options)
  }

  setWebhook(params: SetWebhookParams, options?: InlineBotApiMethodOptions) {
    return this.method("setWebhook", params, options)
  }

  deleteWebhook(params: DeleteWebhookParams = {}, options?: InlineBotApiMethodOptions) {
    return this.method("deleteWebhook", params, options)
  }

  getWebhookInfo(options?: InlineBotApiMethodOptions) {
    return this.method("getWebhookInfo", undefined, options)
  }
}
