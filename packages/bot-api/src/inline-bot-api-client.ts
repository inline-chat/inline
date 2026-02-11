import type {
  BotApiEnvelope,
  BotMethodName,
  BotMethodParamsByName,
  BotMethodResultByName,
  DeleteMessageParams,
  EditMessageTextParams,
  EditMessageTextResult,
  EmptyResult,
  GetChatHistoryParams,
  GetChatHistoryResult,
  GetChatParams,
  GetChatResult,
  GetMeResult,
  InlineBotApiClientOptions,
  InlineBotApiMethodOptions,
  InlineBotApiRequestOptions,
  InlineBotApiResponse,
  SendMessageParams,
  SendMessageResult,
  SendReactionParams,
} from "./types.js"

const defaultBaseUrl = "https://api.inline.chat"

const getMethodNames = new Set<BotMethodName>(["getMe", "getChat", "getChatHistory"])

function isGetMethod(method: string): method is "getMe" | "getChat" | "getChatHistory" {
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

  sendMessage(params: SendMessageParams, options?: InlineBotApiMethodOptions) {
    return this.method("sendMessage", params, options)
  }

  editMessageText(params: EditMessageTextParams, options?: InlineBotApiMethodOptions) {
    return this.method("editMessageText", params, options)
  }

  deleteMessage(params: DeleteMessageParams, options?: InlineBotApiMethodOptions) {
    return this.method("deleteMessage", params, options)
  }

  sendReaction(params: SendReactionParams, options?: InlineBotApiMethodOptions) {
    return this.method("sendReaction", params, options)
  }
}
