import { WebStandardStreamableHTTPServerTransport, type WebStandardStreamableHTTPServerTransportOptions } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js"
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"

export type McpSession = {
  sessionId: string
  grantId: string
  transport: WebStandardStreamableHTTPServerTransport
  server: McpServer
  createdAtMs: number
  lastUsedAtMs: number
  close: () => Promise<void>
}

export class McpSessionManager {
  private readonly sessions = new Map<string, McpSession>()
  private readonly idleTimeoutMs: number

  constructor(options?: { idleTimeoutMs?: number }) {
    this.idleTimeoutMs = options?.idleTimeoutMs ?? 15 * 60 * 1000

    // Best-effort idle cleanup.
    setInterval(() => {
      const now = Date.now()
      for (const s of this.sessions.values()) {
        if (now - s.lastUsedAtMs > this.idleTimeoutMs) {
          void this.close(s.sessionId)
        }
      }
    }, Math.min(60_000, this.idleTimeoutMs)).unref?.()
  }

  get(sessionId: string): McpSession | null {
    return this.sessions.get(sessionId) ?? null
  }

  async close(sessionId: string): Promise<void> {
    const s = this.sessions.get(sessionId)
    if (!s) return
    this.sessions.delete(sessionId)
    await s.close()
  }

  createTransport(params: {
    grantId: string
    nowMs: number
    transportOptions?: Omit<WebStandardStreamableHTTPServerTransportOptions, "sessionIdGenerator" | "onsessioninitialized" | "onsessionclosed">
    // These are created before the first request so transport can deliver the initialize request.
    server: McpServer
    close: () => Promise<void>
  }): { transport: WebStandardStreamableHTTPServerTransport } {
    const transport = new WebStandardStreamableHTTPServerTransport({
      ...(params.transportOptions ?? {}),
      sessionIdGenerator: () => crypto.randomUUID(),
      onsessioninitialized: async (sid: string) => {
        const now = Date.now()
        const close = async () => {
          // Close order: server first, then any external resources.
          await params.server.close().catch(() => undefined)
          await params.close().catch(() => undefined)
        }

        this.sessions.set(sid, {
          sessionId: sid,
          grantId: params.grantId,
          transport,
          server: params.server,
          createdAtMs: now,
          lastUsedAtMs: now,
          close,
        })
      },
      onsessionclosed: async (sid: string) => {
        await this.close(sid)
      },
    })

    return { transport }
  }

  touch(sessionId: string, nowMs: number) {
    const s = this.sessions.get(sessionId)
    if (!s) return
    s.lastUsedAtMs = nowMs
  }
}
