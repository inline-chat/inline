export const API_BASE =
  (import.meta.env.VITE_ADMIN_API_BASE as string | undefined)?.replace(/\/$/, "") ??
  (import.meta.env.PROD ? "https://api.inline.chat" : "")

export type ApiResponse<T> = {
  ok: boolean
  error?: string
  status?: number
} & T

export const apiRequest = async <T>(path: string, init?: RequestInit): Promise<ApiResponse<T>> => {
  try {
    const headers = new Headers(init?.headers ?? {})
    // Only set JSON content-type when the caller didn't already specify one.
    if (typeof init?.body === "string" && !headers.has("content-type")) {
      headers.set("content-type", "application/json")
    }

    const response = await fetch(`${API_BASE}${path}`, {
      credentials: "include",
      cache: "no-store",
      headers,
      ...init,
    })

    const status = response.status
    const contentType = response.headers.get("content-type") ?? ""

    if (status === 204) {
      return { ok: response.ok, status } as ApiResponse<T>
    }

    if (contentType.includes("application/json")) {
      try {
        const body = (await response.json()) as ApiResponse<T>
        const bodyOk = typeof body.ok === "boolean" ? body.ok : response.ok
        const ok = response.ok && bodyOk
        const error = body.error ?? (!response.ok ? `http_${status}` : !bodyOk ? "server_error" : undefined)
        return { ...body, ok, error, status }
      } catch {
        return { ok: false, error: response.ok ? "invalid_response" : `http_${status}`, status } as ApiResponse<T>
      }
    }

    return { ok: false, error: response.ok ? "invalid_response" : `http_${status}`, status } as ApiResponse<T>
  } catch {
    return { ok: false, error: "network_error" } as ApiResponse<T>
  }
}
