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

export async function postJson<T>(path: string, body: Record<string, unknown>): Promise<T> {
  let response: Response
  try {
    response = await fetch(`${appConfig.apiBaseUrl}/v1/${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(body),
    })
  } catch (error) {
    log.error("Request transport failed", error, { path })
    throw error
  }

  const payload = await response.json().catch(() => null)
  if (!response.ok) {
    const message =
      typeof payload?.message === "string"
        ? payload.message
        : typeof payload?.error === "string"
          ? payload.error
        : "Request failed"
    const code = typeof payload?.code === "string" ? payload.code : undefined
    log.warn("Request failed", { path, status: response.status, code })
    throw new ApiError(message, response.status, code)
  }

  return payload as T
}
