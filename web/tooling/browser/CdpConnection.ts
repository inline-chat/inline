export type JsonRecord = Record<string, unknown>

export type CdpMessage = {
  id?: number
  method?: string
  params?: JsonRecord
  result?: JsonRecord
  error?: { message?: string }
  sessionId?: string
}

const isRecord = (value: unknown): value is JsonRecord =>
  typeof value === "object" && value != null

const stringValue = (
  record: JsonRecord | undefined,
  key: string,
) => {
  const value = record?.[key]
  return typeof value === "string" ? value : undefined
}

/**
 * Small browser-process CDP transport. Closing this connection detaches the
 * recorder without closing the inspected Chrome profile.
 */
export class CdpConnection {
  private nextId = 0
  private closed = false
  private readonly pending = new Map<
    number,
    {
      resolve: (result: JsonRecord) => void
      reject: (error: Error) => void
      timeout: ReturnType<typeof setTimeout>
    }
  >()
  private readonly listeners = new Set<
    (message: CdpMessage) => void
  >()

  private constructor(private readonly socket: WebSocket) {
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data)) as CdpMessage
      if (message.id != null) {
        const continuation = this.pending.get(message.id)
        if (continuation) {
          this.pending.delete(message.id)
          clearTimeout(continuation.timeout)
          if (message.error) {
            continuation.reject(
              new Error(
                message.error.message ?? "Chrome command failed",
              ),
            )
          } else {
            continuation.resolve(message.result ?? {})
          }
        }
      }
      for (const listener of this.listeners) listener(message)
    })
    socket.addEventListener("close", () => {
      this.closed = true
      this.rejectPending(
        new Error("Chrome debugger WebSocket closed"),
      )
    })
  }

  static async open(origin: string) {
    const response = await fetch(`${origin}/json/version`)
    if (!response.ok) {
      throw new Error(`Could not inspect Chrome: ${response.status}`)
    }
    const version: unknown = await response.json()
    if (!isRecord(version)) {
      throw new Error("Chrome version response is invalid")
    }
    const webSocketDebuggerUrl = stringValue(
      version,
      "webSocketDebuggerUrl",
    )
    if (!webSocketDebuggerUrl) {
      throw new Error("Chrome did not expose its debugger WebSocket")
    }

    const socket = new WebSocket(webSocketDebuggerUrl)
    await new Promise<void>((resolveOpen, reject) => {
      socket.addEventListener("open", () => resolveOpen(), {
        once: true,
      })
      socket.addEventListener(
        "error",
        () =>
          reject(
            new Error("Chrome debugger WebSocket failed"),
          ),
        { once: true },
      )
    })
    return new CdpConnection(socket)
  }

  call(
    method: string,
    params: JsonRecord = {},
    sessionId?: string,
    timeoutMs = 15_000,
  ) {
    const id = ++this.nextId
    return new Promise<JsonRecord>((resolveCall, reject) => {
      if (
        this.closed ||
        this.socket.readyState !== WebSocket.OPEN
      ) {
        reject(
          new Error("Chrome debugger WebSocket is not open"),
        )
        return
      }
      const timeout = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`Chrome command timed out: ${method}`))
      }, timeoutMs)
      this.pending.set(id, {
        resolve: resolveCall,
        reject,
        timeout,
      })
      try {
        this.socket.send(
          JSON.stringify({
            id,
            method,
            params,
            ...(sessionId ? { sessionId } : {}),
          }),
        )
      } catch (cause) {
        clearTimeout(timeout)
        this.pending.delete(id)
        reject(
          cause instanceof Error
            ? cause
            : new Error(
                `Chrome command could not be sent: ${method}`,
              ),
        )
      }
    })
  }

  onMessage(listener: (message: CdpMessage) => void) {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  async close() {
    if (this.closed) return
    this.closed = true
    this.listeners.clear()
    this.rejectPending(
      new Error("Chrome debugger connection closed"),
    )
    if (this.socket.readyState === WebSocket.CLOSED) return
    const closed = new Promise<void>((resolveClose) => {
      this.socket.addEventListener(
        "close",
        () => resolveClose(),
        { once: true },
      )
    })
    this.socket.close()
    await Promise.race([closed, Bun.sleep(250)])
  }

  private rejectPending(error: Error) {
    for (const continuation of this.pending.values()) {
      clearTimeout(continuation.timeout)
      continuation.reject(error)
    }
    this.pending.clear()
  }
}
