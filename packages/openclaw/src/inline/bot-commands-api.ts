export type InlineBotCommand = {
  command: string
  description: string
  sort_order?: number
  sortOrder?: number
}

type InlineBotApiResponse<T> = {
  ok?: boolean
  result?: T
  description?: string
  error_code?: number
}

export function normalizeInlineBotBaseUrl(baseUrl: string): string {
  return baseUrl.replace(/\/+$/, "")
}

export function normalizeInlineBotCommandName(raw: string): string {
  return raw.trim().replace(/^\/+/, "")
}

export async function callInlineBotApi<T>(params: {
  baseUrl: string
  token: string
  methodName: string
  method: "GET" | "POST"
  body?: unknown
}): Promise<T> {
  const baseUrl = normalizeInlineBotBaseUrl(params.baseUrl)
  const invoke = async (authMode: "header" | "path") => {
    const url =
      authMode === "header"
        ? `${baseUrl}/bot/${params.methodName}`
        : `${baseUrl}/bot${encodeURIComponent(params.token)}/${params.methodName}`
    const request: RequestInit = {
      method: params.method,
      headers: {
        ...(authMode === "header" ? { authorization: `Bearer ${params.token}` } : {}),
        ...(params.body !== undefined ? { "content-type": "application/json" } : {}),
      },
    }
    if (params.body !== undefined) {
      request.body = JSON.stringify(params.body)
    }
    let response: Response
    try {
      response = await fetch(url, request)
    } catch (error) {
      throw new Error(
        `inline_bot_commands: ${params.method} ${redactInlineBotApiUrl(url)} fetch failed: ${summarizeInlineBotApiError(error)}`,
      )
    }
    const payload = (await response.json().catch(() => null)) as InlineBotApiResponse<T> | null
    return { response, payload }
  }

  const resolve = (result: {
    response: Response
    payload: InlineBotApiResponse<T> | null
  }): T => {
    if (!result.response.ok) {
      const message = result.payload?.description ?? `HTTP ${result.response.status}`
      throw new Error(`inline_bot_commands: ${message}`)
    }
    if (!result.payload || result.payload.ok !== true) {
      const message = result.payload?.description ?? "bot api call failed"
      throw new Error(`inline_bot_commands: ${message}`)
    }
    return (result.payload.result ?? ({} as T)) as T
  }

  const shouldRetryWithPathToken = (result: {
    response: Response
    payload: InlineBotApiResponse<T> | null
  }) => {
    if (result.response.status === 401) return true
    if (result.payload?.error_code === 401) return true
    const description = result.payload?.description?.toLowerCase() ?? ""
    return description.includes("unauthorized")
  }

  const headerResult = await invoke("header")
  if (shouldRetryWithPathToken(headerResult)) {
    const pathResult = await invoke("path")
    return resolve(pathResult)
  }
  return resolve(headerResult)
}

function summarizeInlineBotApiError(error: unknown): string {
  if (error instanceof Error) {
    return `${error.name}: ${error.message}`
  }
  return String(error)
}

function redactInlineBotApiUrl(raw: string): string {
  try {
    const url = new URL(raw)
    return `${url.protocol}//${url.host}${url.pathname.replace(/\/bot[^/]*\//, "/bot<redacted>/")}`
  } catch {
    return raw.replace(/\/bot[^/]*\//, "/bot<redacted>/")
  }
}
