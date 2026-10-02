import type { McpConfig } from "../config"

export class EventsRpcError extends Error {
  constructor(readonly code: number, message: string, readonly data?: unknown) {
    super(message)
  }
}

export type EventsProxy = {
  request(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>>
}

/** The API owns durable grants, subscriptions and delivery; MCP never stores bearer tokens. */
export function createEventsProxy(config: McpConfig, token: string, signal?: AbortSignal): EventsProxy {
  return {
    async request(method, params) {
      if (!config.oauthInternalSharedSecret) throw new EventsRpcError(-32603, "Events service is not configured")
      const { _meta: _protocolMetadata, ...eventParams } = params
      let response: Response
      try {
        response = await fetch(`${config.oauthProxyBaseUrl.replace(/\/$/, "")}/oauth/mcp-events`, {
          method: "POST",
          headers: { "content-type": "application/json", "x-inline-mcp-secret": config.oauthInternalSharedSecret },
          body: JSON.stringify({ method, params: eventParams, token }),
          signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(30_000)]) : AbortSignal.timeout(30_000),
        })
      } catch {
        throw new EventsRpcError(-32603, "Events service is temporarily unavailable")
      }
      let value: unknown
      try { value = await response.json() } catch {
        throw new EventsRpcError(-32603, "Events service returned an invalid response")
      }
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new EventsRpcError(-32603, "Events service returned an invalid response")
      }
      const record = value as Record<string, unknown>
      const error = record.error
      if (error && typeof error === "object" && !Array.isArray(error)) {
        const details = error as Record<string, unknown>
        if (typeof details.code === "number" && typeof details.message === "string") {
          throw new EventsRpcError(details.code, details.message, details.data)
        }
      }
      if (!response.ok) throw new EventsRpcError(-32603, "Events service is temporarily unavailable")
      return record
    },
  }
}
