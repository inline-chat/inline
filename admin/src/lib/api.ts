export const API_BASE =
  (import.meta.env.VITE_ADMIN_API_BASE as string | undefined)?.replace(/\/$/, "") ??
  (import.meta.env.PROD ? "https://api.inline.chat" : "")

export type ApiResponse<T> = {
  ok: boolean
  error?: string
} & T

export const apiRequest = async <T>(path: string, init?: RequestInit): Promise<ApiResponse<T>> => {
  try {
    const response = await fetch(`${API_BASE}${path}`, {
      credentials: "include",
      headers: {
        "content-type": "application/json",
        ...(init?.headers ?? {}),
      },
      ...init,
    })

    try {
      return (await response.json()) as ApiResponse<T>
    } catch {
      return { ok: false, error: "invalid_response" } as ApiResponse<T>
    }
  } catch {
    return { ok: false, error: "network_error" } as ApiResponse<T>
  }
}
