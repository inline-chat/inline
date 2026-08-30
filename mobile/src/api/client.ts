import { appConfig } from "@/config/app"
import { createLogger } from "@/observability/logger"

const log = createLogger("api")

export class ApiError extends Error {
  readonly status: number
  readonly code?: string

  constructor(message: string, status: number, code?: string) {
    super(message)
    this.name = "ApiError"
    this.status = status
    this.code = code
  }
}

export async function postJson<T>(
  path: string,
  body: Record<string, unknown>,
  options: { token?: string; timeoutMs?: number } = {},
): Promise<T> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 15_000)
  let response: Response
  try {
    response = await fetch(`${appConfig.apiBaseUrl}/v1/${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        ...(options.token ? { Authorization: `Bearer ${options.token}` } : {}),
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    })
    const payload = await response.json().catch(() => null)
    if (!response.ok || payload?.ok !== true) {
      const message =
        typeof payload?.description === "string" ? payload.description
        : typeof payload?.message === "string" ? payload.message
        : "Request failed"
      const code = typeof payload?.error === "string" ? payload.error
        : typeof payload?.errorCode === "number" ? String(payload.errorCode)
        : typeof payload?.code === "string" ? payload.code : undefined
      log.warn("Request failed", { path, status: response.status, code })
      throw new ApiError(message, response.status, code)
    }
    return payload.result as T
  } catch (error) {
    if (!(error instanceof ApiError)) log.error("Request transport failed", error, { path })
    throw error
  } finally {
    clearTimeout(timer)
  }
}
